//! Integration tests: two real WS clients pair through the router and
//! round-trip opaque frames — proving the router with NO `cloud_bridge`.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, Stream, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use fantastic_router::auth::{Claims, Ed25519Verifier};
use fantastic_router::config::{Config, SUBPROTOCOL};
use fantastic_router::meter::StdoutMeter;
use fantastic_router::rendezvous::InMemoryRendezvous;

fn base_config() -> Config {
    Config {
        listen_addr: "127.0.0.1:0".into(),
        control_plane_pubkey_b64: None,
        control_plane_pubkey_next_b64: None,
        audience: "fantastic.relay".into(),
        require_auth: false,
        require_e2e: false,
        e2e_asserted: true,
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

async fn spawn_router(config: Config) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let config = Arc::new(config);
    let verifier = Arc::new(Ed25519Verifier::from_config(&config).unwrap());
    let rendezvous = Arc::new(InMemoryRendezvous::from_config(&config));
    let meter = Arc::new(StdoutMeter::new());
    let (sh_tx, sh_rx) = watch::channel(false);
    tokio::spawn(async move {
        // Keep the sender alive so the drain path (changed()) never fires in-test.
        let _keep = sh_tx;
        let _ =
            fantastic_router::ws::accept_loop(listener, config, verifier, rendezvous, meter, sh_rx)
                .await;
    });
    addr
}

fn dev_token(tenant: &str, peer: &str, partner: &str, rv: &str) -> String {
    let claims = Claims {
        tenant_id: tenant.into(),
        peer_id: peer.into(),
        rendezvous: rv.into(),
        partner_peer_id: partner.into(),
        aud: "fantastic.relay".into(),
        iat: 0,
        nbf: 0,
        exp: 9_999_999_999,
        jti: String::new(),
    };
    URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap())
}

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(addr: SocketAddr, token: &str) -> Result<Client, WsError> {
    let url = format!("ws://{addr}/");
    let mut req = url.into_client_request().unwrap();
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
async fn dev_pairs_two_clients_and_forwards_both_opcodes() {
    let addr = spawn_router(base_config()).await;

    let mut a = connect(addr, &dev_token("t1", "A", "B", "rv-1"))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await; // A registers first
    let mut b = connect(addr, &dev_token("t1", "B", "A", "rv-1"))
        .await
        .unwrap();

    a.send(Message::Binary(b"ping".to_vec())).await.unwrap();
    assert_eq!(next_msg(&mut b).await, Message::Binary(b"ping".to_vec()));

    b.send(Message::Text("pong".into())).await.unwrap();
    assert_eq!(next_msg(&mut a).await, Message::Text("pong".into()));
}

#[tokio::test]
async fn dev_rejects_self_pair() {
    let addr = spawn_router(base_config()).await;

    // Same peer_id on both legs of the same rendezvous → the second is rejected.
    let _a = connect(addr, &dev_token("t1", "A", "", "rv-self"))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut a2 = connect(addr, &dev_token("t1", "A", "", "rv-self"))
        .await
        .unwrap();

    match next_msg(&mut a2).await {
        Message::Close(_) => {}
        other => panic!("expected Close on self-pair, got {other:?}"),
    }
}

#[tokio::test]
async fn strict_pairs_with_signed_tokens() {
    let mut sk = [0u8; 32];
    getrandom::getrandom(&mut sk).unwrap();
    let signing = SigningKey::from_bytes(&sk);
    let pub_b64 = STANDARD.encode(signing.verifying_key().to_bytes());

    let mut config = base_config();
    config.require_auth = true;
    config.control_plane_pubkey_b64 = Some(pub_b64);
    let addr = spawn_router(config).await;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let sign = |peer: &str, partner: &str| -> String {
        let claims = Claims {
            tenant_id: "t1".into(),
            peer_id: peer.into(),
            rendezvous: "rv-strict".into(),
            partner_peer_id: partner.into(),
            aud: "fantastic.relay".into(),
            iat: now,
            nbf: 0,
            exp: now + 60,
            jti: format!("jti-{peer}"),
        };
        let payload = serde_json::to_vec(&claims).unwrap();
        let sig = signing.sign(&payload);
        format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(&payload),
            URL_SAFE_NO_PAD.encode(sig.to_bytes())
        )
    };

    let mut a = connect(addr, &sign("A", "B")).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut b = connect(addr, &sign("B", "A")).await.unwrap();

    a.send(Message::Binary(b"secret".to_vec())).await.unwrap();
    assert_eq!(next_msg(&mut b).await, Message::Binary(b"secret".to_vec()));
}

#[tokio::test]
async fn strict_rejects_bad_token() {
    let mut sk = [0u8; 32];
    getrandom::getrandom(&mut sk).unwrap();
    let signing = SigningKey::from_bytes(&sk);
    let pub_b64 = STANDARD.encode(signing.verifying_key().to_bytes());

    let mut config = base_config();
    config.require_auth = true;
    config.control_plane_pubkey_b64 = Some(pub_b64);
    let addr = spawn_router(config).await;

    // A token signed by a DIFFERENT key → verification fails → 401 pre-upgrade.
    let mut other = [0u8; 32];
    getrandom::getrandom(&mut other).unwrap();
    let wrong = SigningKey::from_bytes(&other);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let claims = Claims {
        tenant_id: "t1".into(),
        peer_id: "A".into(),
        rendezvous: "rv-x".into(),
        partner_peer_id: "B".into(),
        aud: "fantastic.relay".into(),
        iat: now,
        nbf: 0,
        exp: now + 60,
        jti: "j".into(),
    };
    let payload = serde_json::to_vec(&claims).unwrap();
    let sig = wrong.sign(&payload);
    let token = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(&payload),
        URL_SAFE_NO_PAD.encode(sig.to_bytes())
    );

    assert!(
        connect(addr, &token).await.is_err(),
        "bad token must be rejected pre-upgrade"
    );
}
