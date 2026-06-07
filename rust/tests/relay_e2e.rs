//! Full Rust path: mint a token with the `Issuer` → start the relay via the
//! embed API (`ws::start` → `ServerHandle`) → two WS clients pair through it and
//! round-trip frames. The parity counterpart to the Swift `RelayE2ETests`.

use std::sync::Arc;
use std::time::Duration;

use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, Stream, StreamExt};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use fantastic_router::auth::Ed25519Verifier;
use fantastic_router::config::{Config, SUBPROTOCOL};
use fantastic_router::issuer::{Issuer, PasswordProvider};
use fantastic_router::meter::StdoutMeter;
use fantastic_router::rendezvous::InMemoryRendezvous;

fn config(pubkey_b64: String) -> Config {
    Config {
        listen_addr: "127.0.0.1:0".into(),
        control_plane_pubkey_b64: Some(pubkey_b64),
        control_plane_pubkey_next_b64: None,
        audience: "fantastic.relay".into(),
        pair_timeout_secs: 3,
        max_frame_bytes: 16 << 20,
        max_session_bytes: 1 << 30,
        max_conns_global: 100,
        max_conns_per_ip: 100,
        max_waiting_global: 100,
        max_waiting_per_tenant: 100,
        token_max_lifetime_secs: 120,
        heartbeat_secs: 60,
    }
}

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(addr: std::net::SocketAddr, token: &str) -> Result<Client, WsError> {
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
    tokio::time::timeout(Duration::from_secs(3), ws.next())
        .await
        .expect("recv timed out")
        .expect("stream ended")
        .expect("ws error")
}

#[tokio::test]
async fn issue_start_pair_forward() {
    // Issuer (control plane) — holds the signing key.
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).unwrap();
    let issuer = Issuer::new(SigningKey::from_bytes(&seed), "fantastic.relay", 60)
        .with_provider(Box::new(PasswordProvider::new("pw", "t1")));

    // Relay (verifier) — holds only the public key. Start via the embed handle.
    let config = config(issuer.public_key_b64());
    let verifier = Arc::new(Ed25519Verifier::from_config(&config).unwrap());
    let rendezvous = Arc::new(InMemoryRendezvous::from_config(&config));
    let meter = Arc::new(StdoutMeter::new());
    let handle = fantastic_router::ws::start(config, verifier, rendezvous, meter)
        .await
        .expect("start");
    let addr = handle.local_addr();

    let token_a = issuer.issue("password", "pw", "A", "B", "rv").unwrap();
    let token_b = issuer.issue("password", "pw", "B", "A", "rv").unwrap();

    let mut a = connect(addr, &token_a).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut b = connect(addr, &token_b).await.unwrap();

    a.send(Message::Binary(b"ping".to_vec())).await.unwrap();
    assert_eq!(next_msg(&mut b).await, Message::Binary(b"ping".to_vec()));

    b.send(Message::Text("pong".into())).await.unwrap();
    assert_eq!(next_msg(&mut a).await, Message::Text("pong".into()));

    handle.shutdown().await;
}
