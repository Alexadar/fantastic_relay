//! WebSocket accept loop + strict subprotocol auth.
//!
//! Auth happens AT the HTTP handshake: the client offers
//! `Sec-WebSocket-Protocol: fantastic.relay.v1, <base64url-token>`. A
//! missing/invalid token returns HTTP 401 BEFORE the upgrade — no socket, no
//! pairing slot. On success the connection is split and handed to the
//! rendezvous; the rendezvous arrives INSIDE the verified Claims, never the URL
//! path (no local namespace to address). Pre-auth DoS is bounded by a global
//! connection semaphore + a per-source-IP cap, applied before any allocation.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::{watch, Semaphore};
use tokio_tungstenite::accept_hdr_async_with_config;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, WebSocketConfig};
use tokio_tungstenite::tungstenite::Message;

use crate::auth::{Claims, Ed25519Verifier, TokenVerifier};
use crate::config::{Config, SUBPROTOCOL};
use crate::forward::{self, Session};
use crate::meter::StdoutMeter;
use crate::rendezvous::{InMemoryRendezvous, Join, PeerSocket};

/// Bind `config.listen_addr` and serve until SIGTERM / Ctrl-C.
pub async fn serve(
    config: Config,
    verifier: Arc<Ed25519Verifier>,
    rendezvous: Arc<InMemoryRendezvous>,
    meter: Arc<StdoutMeter>,
) -> anyhow::Result<()> {
    // E2E launch-gate: the endpoints have no peer E2E layer yet, so in a
    // production posture we refuse to carry plaintext.
    if config.require_e2e && !config.e2e_asserted {
        anyhow::bail!(
            "refusing to launch: ROUTER_REQUIRE_E2E is set but ROUTER_E2E_ASSERTED is not. \
             The endpoints have no end-to-end encryption yet, so carrying production traffic \
             would expose plaintext to this relay. Set ROUTER_E2E_ASSERTED=true only once \
             cloud_bridge ships Noise E2E, or ROUTER_REQUIRE_E2E=false for non-prod use."
        );
    }
    if !config.e2e_asserted {
        tracing::warn!(
            "PLAINTEXT MODE: payloads are NOT end-to-end encrypted; a relay/tunnel compromise \
             leaks full content. Do not carry production traffic."
        );
    }
    if !config.require_auth {
        tracing::warn!(
            "DEV MODE: ROUTER_REQUIRE_AUTH=false — tokens are parsed but NOT verified. \
             Never run this in production."
        );
    }

    let (sh_tx, sh_rx) = watch::channel(false);
    spawn_signal_handler(sh_tx);

    let listener = TcpListener::bind(&config.listen_addr).await?;
    tracing::info!(addr = %config.listen_addr, "router listening");

    accept_loop(
        listener,
        Arc::new(config),
        verifier,
        rendezvous,
        meter,
        sh_rx,
    )
    .await
}

/// The accept loop, factored out so tests can drive it on an arbitrary listener
/// + shutdown channel.
pub async fn accept_loop(
    listener: TcpListener,
    config: Arc<Config>,
    verifier: Arc<Ed25519Verifier>,
    rendezvous: Arc<InMemoryRendezvous>,
    meter: Arc<StdoutMeter>,
    sh_rx: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let conn_sem = Arc::new(Semaphore::new(config.max_conns_global));
    let per_ip: Arc<DashMap<IpAddr, usize>> = Arc::new(DashMap::new());
    let mut sh_accept = sh_rx.clone();

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (tcp, addr) = match accepted {
                    Ok(v) => v,
                    Err(e) => { tracing::warn!(error = %e, "accept failed"); continue; }
                };
                let ip = addr.ip();

                let permit = match Arc::clone(&conn_sem).try_acquire_owned() {
                    Ok(p) => p,
                    Err(_) => { tracing::warn!("global connection cap reached; dropping"); continue; }
                };
                if !ip_admit(&per_ip, ip, config.max_conns_per_ip) {
                    tracing::warn!(%ip, "per-ip connection cap reached; dropping");
                    drop(permit);
                    continue;
                }

                let verifier = Arc::clone(&verifier);
                let rendezvous = Arc::clone(&rendezvous);
                let meter = Arc::clone(&meter);
                let config = Arc::clone(&config);
                let per_ip = Arc::clone(&per_ip);
                let sh_rx = sh_rx.clone();
                tokio::spawn(async move {
                    let _permit = permit; // held for the connection's lifetime
                    let _ip_guard = IpGuard { map: per_ip, ip };
                    if let Err(e) = handle_conn(tcp, config, verifier, rendezvous, meter, sh_rx).await {
                        tracing::debug!(error = %e, "connection ended");
                    }
                });
            }
            _ = sh_accept.changed() => {
                if *sh_accept.borrow() {
                    tracing::info!("draining: no longer accepting connections");
                    break;
                }
            }
        }
    }

    // Brief grace so in-flight sessions (which watch the same channel) drain.
    tokio::time::sleep(Duration::from_secs(2)).await;
    Ok(())
}

// The accept_hdr callback's Err variant is `http::Response<Option<String>>`,
// whose size is fixed by the tungstenite API — we can't box it away.
#[allow(clippy::result_large_err)]
async fn handle_conn(
    tcp: tokio::net::TcpStream,
    config: Arc<Config>,
    verifier: Arc<Ed25519Verifier>,
    rendezvous: Arc<InMemoryRendezvous>,
    meter: Arc<StdoutMeter>,
    shutdown: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let ws_config = WebSocketConfig {
        max_message_size: Some(config.max_frame_bytes),
        max_frame_size: Some(config.max_frame_bytes),
        ..Default::default()
    };

    let mut captured: Option<Claims> = None;
    let verifier_ref = verifier.as_ref();
    let result = {
        let cap = &mut captured;
        accept_hdr_async_with_config(
            tcp,
            |req: &Request, mut resp: Response| match authenticate(req, verifier_ref) {
                Ok(claims) => {
                    resp.headers_mut().append(
                        "Sec-WebSocket-Protocol",
                        http::HeaderValue::from_static(SUBPROTOCOL),
                    );
                    *cap = Some(claims);
                    Ok(resp)
                }
                Err(()) => {
                    let er: ErrorResponse = http::Response::builder()
                        .status(http::StatusCode::UNAUTHORIZED)
                        .body(Some("unauthorized".to_string()))
                        .expect("static 401 response");
                    Err(er)
                }
            },
            Some(ws_config),
        )
        .await
    };

    let ws = match result {
        Ok(ws) => ws,
        // Handshake rejected (401 already sent) or failed — strict abort.
        Err(_) => return Ok(()),
    };
    let claims = match captured {
        Some(c) => c,
        None => return Ok(()),
    };

    let session_id = meter.session_id(&claims.rendezvous);
    let tenant_id = claims.tenant_id.clone();

    let (sink, stream) = ws.split();
    let socket = PeerSocket {
        stream: Box::pin(stream),
        sink: Box::pin(sink),
        claims,
    };

    match rendezvous.join(socket) {
        Join::Rejected { socket, reason } => {
            tracing::debug!(reason, "pairing rejected");
            close_socket(socket, CloseCode::Policy, reason).await;
        }
        Join::Waiting(ticket) => {
            // First arrival: park until paired or timeout (guard cleans up).
            let _ = ticket
                .settle(Duration::from_secs(config.pair_timeout_secs))
                .await;
        }
        Join::Paired { a, b } => {
            let session = Session {
                meter: meter.as_ref(),
                tenant_id,
                session_id,
                max_frame_bytes: config.max_frame_bytes,
                max_session_bytes: config.max_session_bytes,
                heartbeat: Duration::from_secs(config.heartbeat_secs.max(1)),
            };
            forward::run(a, b, shutdown, session).await;
        }
    }
    Ok(())
}

/// Extract + verify the token from the `Sec-WebSocket-Protocol` header.
fn authenticate(req: &Request, verifier: &Ed25519Verifier) -> Result<Claims, ()> {
    let protocols = req
        .headers()
        .get("Sec-WebSocket-Protocol")
        .and_then(|v| v.to_str().ok())
        .ok_or(())?;

    let mut marker = false;
    let mut token: Option<&str> = None;
    for p in protocols.split(',') {
        let p = p.trim();
        if p == SUBPROTOCOL {
            marker = true;
        } else if !p.is_empty() {
            token = Some(p);
        }
    }
    if !marker {
        return Err(());
    }
    let token = token.ok_or(())?;
    verifier.verify(token).map_err(|_| ())
}

async fn close_socket(mut socket: PeerSocket, code: CloseCode, reason: &'static str) {
    let _ = socket
        .sink
        .send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        })))
        .await;
    let _ = socket.sink.close().await;
}

fn ip_admit(map: &DashMap<IpAddr, usize>, ip: IpAddr, cap: usize) -> bool {
    let mut e = map.entry(ip).or_insert(0);
    if *e >= cap {
        return false;
    }
    *e += 1;
    true
}

struct IpGuard {
    map: Arc<DashMap<IpAddr, usize>>,
    ip: IpAddr,
}

impl Drop for IpGuard {
    fn drop(&mut self) {
        if let Some(mut e) = self.map.get_mut(&self.ip) {
            if *e > 0 {
                *e -= 1;
            }
        }
    }
}

fn spawn_signal_handler(tx: watch::Sender<bool>) {
    tokio::spawn(async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            match signal(SignalKind::terminate()) {
                Ok(mut term) => {
                    tokio::select! {
                        _ = term.recv() => {}
                        _ = tokio::signal::ctrl_c() => {}
                    }
                }
                Err(_) => {
                    let _ = tokio::signal::ctrl_c().await;
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        tracing::info!("shutdown signal received");
        let _ = tx.send(true);
    });
}
