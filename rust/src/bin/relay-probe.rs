//! relay-probe — a minimal WS client that exercises the router without the real
//! `cloud_bridge` endpoint transport. Two probes sharing a rendezvous pair up
//! and round-trip opaque frames.
//!
//! Env:
//!   PROBE_URL     ws://127.0.0.1:9443/        (router URL)
//!   PROBE_TENANT  t1
//!   PROBE_PEER    A                           (this peer's id)
//!   PROBE_PARTNER B                           (expected counterpart id; optional)
//!   PROBE_RV      demo                         (shared rendezvous id)
//!   PROBE_SEND    "hello from A"               (optional: send one frame, then listen)
//!
//! Auth: in dev mode (router `ROUTER_REQUIRE_AUTH=false`) the token is just the
//! base64url-encoded claims JSON (no signature). Point both probes at the same
//! PROBE_RV with distinct PROBE_PEER values.

use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

use fantastic_router::config::SUBPROTOCOL;

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let url = env("PROBE_URL", "ws://127.0.0.1:9443/");
    let tenant = env("PROBE_TENANT", "t1");
    let peer = env("PROBE_PEER", "A");
    let partner = env("PROBE_PARTNER", "");
    let rv = env("PROBE_RV", "demo");
    let send = std::env::var("PROBE_SEND").ok();

    // Dev token: base64url(claims_json), no signature.
    let claims = json!({
        "tenant_id": tenant,
        "peer_id": peer,
        "rendezvous": rv,
        "partner_peer_id": partner,
        "aud": "fantastic.relay",
        "exp": 9_999_999_999u64,
    });
    let token = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims)?);

    let mut req = url.as_str().into_client_request()?;
    req.headers_mut().append(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_str(&format!("{SUBPROTOCOL}, {token}"))?,
    );

    let (mut ws, _resp) = connect_async(req).await?;
    tracing::info!(%peer, %rv, "connected; waiting for pair");

    if let Some(msg) = send {
        // Give the peer a moment to attach, then send one opaque binary frame.
        tokio::time::sleep(Duration::from_millis(300)).await;
        ws.send(Message::Binary(msg.into_bytes())).await?;
        tracing::info!("sent one frame");
    }

    // Listen for forwarded frames for a while, printing whatever arrives.
    loop {
        match tokio::time::timeout(Duration::from_secs(30), ws.next()).await {
            Ok(Some(Ok(Message::Binary(b)))) => {
                tracing::info!(
                    bytes = b.len(),
                    "recv binary: {:?}",
                    String::from_utf8_lossy(&b)
                );
            }
            Ok(Some(Ok(Message::Text(t)))) => tracing::info!("recv text: {t}"),
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => {
                tracing::info!("peer closed");
                break;
            }
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(e))) => {
                tracing::warn!(error = %e, "ws error");
                break;
            }
            Err(_) => {
                tracing::info!("idle timeout; exiting");
                break;
            }
        }
    }
    Ok(())
}
