//! Language-agnostic conformance runner for the Fantastic Relay (CONTRACT v1).
//!
//! Boots a relay binary (`fantastic-router` or `relayd`) as a subprocess, points
//! it at a fresh Ed25519 issuer key, and drives real WebSocket clients through
//! it to assert behavioural parity: strict subprotocol auth, single-use
//! `(tenant, rendezvous)` pairing, and opaque Text+Binary forwarding.
//!
//! Usage: `conformance <relay-binary> [<relay-binary> ...]`

use std::net::SocketAddr;
use std::process::Stdio;
use std::time::Duration;

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, Stream, StreamExt};
use serde_json::json;
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

const SUBPROTOCOL: &str = "fantastic.relay.v1";
const AUDIENCE: &str = "fantastic.relay";

struct Issuer {
    signing: SigningKey,
}

impl Issuer {
    fn new() -> Self {
        let mut seed = [0u8; 32];
        getrandom::getrandom(&mut seed).expect("getrandom");
        Self {
            signing: SigningKey::from_bytes(&seed),
        }
    }
    fn pubkey_b64(&self) -> String {
        STANDARD.encode(self.signing.verifying_key().to_bytes())
    }
    fn token(&self, peer: &str, partner: &str, rendezvous: &str, lifetime: u64) -> String {
        self.token_for("t1", peer, partner, rendezvous, lifetime)
    }

    fn token_for(
        &self,
        tenant: &str,
        peer: &str,
        partner: &str,
        rendezvous: &str,
        lifetime: u64,
    ) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // Unique jti per mint — tokens are single-use even when two legs share
        // the same peer/rendezvous (e.g. the self-pair scenario).
        let mut nonce = [0u8; 8];
        getrandom::getrandom(&mut nonce).unwrap();
        let jti = format!("{peer}-{rendezvous}-{}", URL_SAFE_NO_PAD.encode(nonce));
        let claims = json!({
            "tenant_id": tenant,
            "peer_id": peer,
            "rendezvous": rendezvous,
            "partner_peer_id": partner,
            "aud": AUDIENCE,
            "iat": now,
            "nbf": 0,
            "exp": now + lifetime,
            "jti": jti,
        });
        let payload = serde_json::to_vec(&claims).unwrap();
        let sig = self.signing.sign(&payload);
        format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(&payload),
            URL_SAFE_NO_PAD.encode(sig.to_bytes())
        )
    }
}

/// Subprocess that is killed on drop.
struct Relay {
    child: Child,
    addr: SocketAddr,
}

impl Relay {
    async fn boot(binary: &str, issuer: &Issuer) -> anyhow::Result<Self> {
        let port = free_port();
        let addr: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
        let child = Command::new(binary)
            .env("ROUTER_LISTEN_ADDR", addr.to_string())
            .env("ROUTER_CONTROL_PLANE_PUBKEY", issuer.pubkey_b64())
            .env("ROUTER_AUDIENCE", AUDIENCE)
            .env("ROUTER_PAIR_TIMEOUT_SECS", "2")
            .env("ROUTER_MAX_FRAME_BYTES", "65536")
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()?;
        // Wait for the listener.
        for _ in 0..100 {
            if TcpStream::connect(addr).await.is_ok() {
                return Ok(Self { child, addr });
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        anyhow::bail!("relay {binary} did not start listening on {addr}");
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

fn free_port() -> u16 {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let p = l.local_addr().unwrap().port();
    drop(l);
    p
}

type Client = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

async fn connect(addr: SocketAddr, token: &str) -> Result<Client, WsError> {
    let mut req = format!("ws://{addr}/").into_client_request().unwrap();
    req.headers_mut().append(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_str(&format!("{SUBPROTOCOL}, {token}")).unwrap(),
    );
    connect_async(req).await.map(|(ws, _)| ws)
}

async fn next_msg<S>(ws: &mut S) -> Message
where
    S: Stream<Item = Result<Message, WsError>> + Unpin,
{
    tokio::time::timeout(Duration::from_secs(4), ws.next())
        .await
        .expect("recv timed out")
        .expect("stream ended")
        .expect("ws error")
}

/// Drains until a Close (or stream end), returning true if the connection closed.
async fn expect_close<S>(ws: &mut S) -> bool
where
    S: Stream<Item = Result<Message, WsError>> + Unpin,
{
    for _ in 0..8 {
        match tokio::time::timeout(Duration::from_secs(4), ws.next()).await {
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => return true,
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(_))) | Err(_) => return true,
        }
    }
    false
}

async fn scenario_pair_and_forward(addr: SocketAddr, issuer: &Issuer) -> anyhow::Result<()> {
    let mut a = connect(addr, &issuer.token("A", "B", "rv-fwd", 60)).await?;
    tokio::time::sleep(Duration::from_millis(80)).await;
    let mut b = connect(addr, &issuer.token("B", "A", "rv-fwd", 60)).await?;

    a.send(Message::Binary(b"ping-bytes".to_vec())).await?;
    anyhow::ensure!(
        next_msg(&mut b).await == Message::Binary(b"ping-bytes".to_vec()),
        "A->B binary mismatch"
    );

    b.send(Message::Text("pong-text".into())).await?;
    anyhow::ensure!(
        next_msg(&mut a).await == Message::Text("pong-text".into()),
        "B->A text mismatch"
    );
    Ok(())
}

async fn scenario_self_pair_rejected(addr: SocketAddr, issuer: &Issuer) -> anyhow::Result<()> {
    let _a = connect(addr, &issuer.token("A", "", "rv-self", 60)).await?;
    tokio::time::sleep(Duration::from_millis(80)).await;
    let mut a2 = connect(addr, &issuer.token("A", "", "rv-self", 60)).await?;
    anyhow::ensure!(
        expect_close(&mut a2).await,
        "self-pair should close the second leg"
    );
    Ok(())
}

async fn scenario_partner_mismatch_rejected(
    addr: SocketAddr,
    issuer: &Issuer,
) -> anyhow::Result<()> {
    let _a = connect(addr, &issuer.token("A", "B", "rv-pm", 60)).await?;
    tokio::time::sleep(Duration::from_millis(80)).await;
    // Second leg's partner ("A") matches, but first leg expected partner "B" != "C".
    let mut c = connect(addr, &issuer.token("C", "A", "rv-pm", 60)).await?;
    anyhow::ensure!(
        expect_close(&mut c).await,
        "partner-mismatch should close the second leg"
    );
    Ok(())
}

async fn scenario_bad_token_rejected(addr: SocketAddr, _issuer: &Issuer) -> anyhow::Result<()> {
    // A token signed by a DIFFERENT issuer → 401 pre-upgrade.
    let other = Issuer::new();
    let token = other.token("A", "B", "rv-bad", 60);
    anyhow::ensure!(
        connect(addr, &token).await.is_err(),
        "bad token must be rejected pre-upgrade"
    );
    Ok(())
}

async fn scenario_ping_pong(addr: SocketAddr, issuer: &Issuer) -> anyhow::Result<()> {
    let mut a = connect(addr, &issuer.token("A", "B", "rv-ping", 60)).await?;
    tokio::time::sleep(Duration::from_millis(80)).await;
    let mut _b = connect(addr, &issuer.token("B", "A", "rv-ping", 60)).await?;

    a.send(Message::Ping(b"hi".to_vec())).await?;
    // Expect a Pong back (auto-replied per hop, not cross-forwarded).
    for _ in 0..8 {
        match next_msg(&mut a).await {
            Message::Pong(_) => return Ok(()),
            _ => continue,
        }
    }
    anyhow::bail!("no Pong received after Ping");
}

async fn scenario_pair_timeout(addr: SocketAddr, issuer: &Issuer) -> anyhow::Result<()> {
    let mut alone = connect(addr, &issuer.token("A", "B", "rv-timeout", 60)).await?;
    // ROUTER_PAIR_TIMEOUT_SECS=2 → the unpaired leg should be closed.
    anyhow::ensure!(
        expect_close(&mut alone).await,
        "unpaired leg should close after pair timeout"
    );
    Ok(())
}

async fn scenario_tenant_isolation(addr: SocketAddr, issuer: &Issuer) -> anyhow::Result<()> {
    // Two tenants quote the SAME rendezvous; they must pair within a tenant and
    // never cross.
    let mut a = connect(addr, &issuer.token_for("t1", "A", "", "shared", 60)).await?;
    let mut c = connect(addr, &issuer.token_for("t2", "C", "", "shared", 60)).await?;
    tokio::time::sleep(Duration::from_millis(80)).await;
    let mut b = connect(addr, &issuer.token_for("t1", "B", "", "shared", 60)).await?;
    let mut d = connect(addr, &issuer.token_for("t2", "D", "", "shared", 60)).await?;

    a.send(Message::Binary(b"t1-only".to_vec())).await?;
    anyhow::ensure!(
        next_msg(&mut b).await == Message::Binary(b"t1-only".to_vec()),
        "tenant t1 A->B mismatch"
    );
    c.send(Message::Binary(b"t2-only".to_vec())).await?;
    anyhow::ensure!(
        next_msg(&mut d).await == Message::Binary(b"t2-only".to_vec()),
        "tenant t2 C->D mismatch"
    );
    Ok(())
}

async fn run_all(binary: &str) -> anyhow::Result<()> {
    println!("== conformance against `{binary}` ==");
    let issuer = Issuer::new();

    // Each scenario reboots a fresh relay so state never leaks across cases.
    let cases = [
        "pair_and_forward",
        "self_pair_rejected",
        "partner_mismatch_rejected",
        "bad_token_rejected",
        "ping_pong",
        "pair_timeout",
        "tenant_isolation",
    ];

    for name in cases {
        let relay = Relay::boot(binary, &issuer).await?;
        let addr = relay.addr;
        let result = match name {
            "pair_and_forward" => scenario_pair_and_forward(addr, &issuer).await,
            "self_pair_rejected" => scenario_self_pair_rejected(addr, &issuer).await,
            "partner_mismatch_rejected" => scenario_partner_mismatch_rejected(addr, &issuer).await,
            "bad_token_rejected" => scenario_bad_token_rejected(addr, &issuer).await,
            "ping_pong" => scenario_ping_pong(addr, &issuer).await,
            "pair_timeout" => scenario_pair_timeout(addr, &issuer).await,
            "tenant_isolation" => scenario_tenant_isolation(addr, &issuer).await,
            _ => unreachable!(),
        };
        drop(relay);
        match result {
            Ok(()) => println!("  ok   {name}"),
            Err(e) => {
                println!("  FAIL {name}: {e:#}");
                anyhow::bail!("conformance failed for `{binary}` at `{name}`");
            }
        }
    }
    println!("== all conformance scenarios passed for `{binary}` ==");
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let binaries: Vec<String> = std::env::args().skip(1).collect();
    if binaries.is_empty() {
        eprintln!("usage: conformance <relay-binary> [<relay-binary> ...]");
        std::process::exit(2);
    }
    for binary in &binaries {
        run_all(binary).await?;
    }
    println!("ALL CONFORMANCE PASSED ({} binaries)", binaries.len());
    Ok(())
}
