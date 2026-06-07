//! relay-probe — a minimal WS client that exercises the router without the real
//! `cloud_bridge` endpoint transport. Two probes sharing a rendezvous pair up
//! and round-trip opaque frames.
//!
//! Mint a token with `fantastic-issue` (the token carries peer_id + rendezvous),
//! then:
//!   PROBE_URL    ws://127.0.0.1:9443/        (router URL)
//!   PROBE_TOKEN  <token>                     (from `fantastic-issue token …`)
//!   PROBE_SEND   "hello"                      (optional: send one frame, then listen)
//!
//! Point both probes at the same rendezvous (via their tokens) with distinct
//! peer_ids.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

use fantastic_router::config::SUBPROTOCOL;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let url = std::env::var("PROBE_URL").unwrap_or_else(|_| "ws://127.0.0.1:9443/".into());
    let token = std::env::var("PROBE_TOKEN").map_err(|_| {
        anyhow::anyhow!("PROBE_TOKEN is required (mint one with `fantastic-issue`)")
    })?;
    let send = std::env::var("PROBE_SEND").ok();

    let mut req = url.as_str().into_client_request()?;
    req.headers_mut().append(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_str(&format!("{SUBPROTOCOL}, {token}"))?,
    );

    let (mut ws, _resp) = connect_async(req).await?;
    tracing::info!("connected; waiting for pair");

    if let Some(msg) = send {
        tokio::time::sleep(Duration::from_millis(300)).await;
        ws.send(Message::Binary(msg.into_bytes())).await?;
        tracing::info!("sent one frame");
    }

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
