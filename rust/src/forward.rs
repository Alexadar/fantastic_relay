//! Opaque bidirectional forwarding.
//!
//! Two independent pump tasks copy frames A→B and B→A, preserving the opcode
//! (Text and Binary both — cloud_bridge sends Binary TLS ciphertext, with the
//! kernels' tagged `[len | tag | wire]` records inside), never inspecting
//! the payload. Control frames (Ping/Pong) are NOT cross-forwarded; tungstenite
//! auto-Pongs each hop locally, so each pump periodically flushes its sink to
//! push those queued pongs out even on a quiet direction. A Close is forwarded,
//! then that direction half-closes. Backpressure is await-on-send only — no
//! unbounded buffering.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::sync::{watch, Notify};
use tokio::time::interval;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::meter::{Meter, UsageEvent, UsageKind};
use crate::rendezvous::{FrameSink, FrameStream, PeerSocket};

/// How often each pump flushes its sink so queued auto-pongs go out on an idle
/// direction (keeps the connection alive past a CDN idle timeout).
const FLUSH_INTERVAL: Duration = Duration::from_secs(1);

/// Per-session parameters + the metering sink.
pub struct Session<'a> {
    pub meter: &'a dyn Meter,
    pub tenant_id: String,
    pub session_id: String,
    pub max_frame_bytes: usize,
    pub max_session_bytes: u64,
    pub heartbeat: Duration,
}

/// Drive a paired session to completion, emitting a final `SessionClose` event.
pub async fn run(a: PeerSocket, b: PeerSocket, shutdown: watch::Receiver<bool>, s: Session<'_>) {
    let a2b = Arc::new(AtomicU64::new(0));
    let b2a = Arc::new(AtomicU64::new(0));
    let seq = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(Notify::new());
    let started = Instant::now();

    let PeerSocket {
        stream: a_stream,
        sink: a_sink,
        ..
    } = a;
    let PeerSocket {
        stream: b_stream,
        sink: b_sink,
        ..
    } = b;

    let p1 = pump(
        a_stream,
        b_sink,
        Arc::clone(&a2b),
        s.max_frame_bytes,
        s.max_session_bytes,
        Arc::clone(&stop),
        shutdown.clone(),
    );
    let p2 = pump(
        b_stream,
        a_sink,
        Arc::clone(&b2a),
        s.max_frame_bytes,
        s.max_session_bytes,
        Arc::clone(&stop),
        shutdown.clone(),
    );
    let hb = heartbeat(
        &s,
        &a2b,
        &b2a,
        &seq,
        started,
        Arc::clone(&stop),
        shutdown.clone(),
    );

    tokio::join!(p1, p2, hb);

    let ev = UsageEvent::new(
        UsageKind::SessionClose,
        &s.tenant_id,
        &s.session_id,
        seq.fetch_add(1, Ordering::SeqCst),
        a2b.load(Ordering::SeqCst),
        b2a.load(Ordering::SeqCst),
        started.elapsed().as_secs(),
    );
    s.meter.record(&ev);
}

async fn heartbeat(
    s: &Session<'_>,
    a2b: &AtomicU64,
    b2a: &AtomicU64,
    seq: &AtomicU64,
    started: Instant,
    stop: Arc<Notify>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut iv = interval(s.heartbeat);
    iv.tick().await; // consume the immediate first tick
    loop {
        tokio::select! {
            _ = iv.tick() => {
                let ev = UsageEvent::new(
                    UsageKind::Heartbeat,
                    &s.tenant_id,
                    &s.session_id,
                    seq.fetch_add(1, Ordering::SeqCst),
                    a2b.load(Ordering::SeqCst),
                    b2a.load(Ordering::SeqCst),
                    started.elapsed().as_secs(),
                );
                s.meter.record(&ev);
            }
            _ = stop.notified() => break,
            _ = shutdown.changed() => break,
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn pump(
    mut src: FrameStream,
    mut dst: FrameSink,
    counter: Arc<AtomicU64>,
    max_frame: usize,
    max_session: u64,
    stop: Arc<Notify>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut flush_iv = interval(FLUSH_INTERVAL);
    flush_iv.tick().await; // consume immediate tick
    loop {
        tokio::select! {
            msg = src.next() => match msg {
                Some(Ok(m)) => {
                    match m {
                        Message::Binary(_) | Message::Text(_) => {
                            let len = match &m {
                                Message::Binary(b) => b.len(),
                                Message::Text(t) => t.len(),
                                _ => 0,
                            };
                            if len > max_frame {
                                let _ = send_close(&mut dst, CloseCode::Size, "frame too large").await;
                                break;
                            }
                            let total = counter.fetch_add(len as u64, Ordering::SeqCst) + len as u64;
                            if total > max_session {
                                let _ = send_close(&mut dst, CloseCode::Policy, "session byte cap").await;
                                break;
                            }
                            if dst.send(m).await.is_err() {
                                break;
                            }
                        }
                        Message::Close(cf) => {
                            let _ = dst.send(Message::Close(cf)).await;
                            break;
                        }
                        // Do NOT cross-forward control frames; just flush so any
                        // auto-pong queued on this sink goes out.
                        Message::Ping(_) | Message::Pong(_) => {
                            let _ = dst.flush().await;
                        }
                        Message::Frame(_) => {}
                    }
                }
                Some(Err(_)) => break,
                None => break,
            },
            _ = flush_iv.tick() => { let _ = dst.flush().await; }
            _ = stop.notified() => break,
            _ = shutdown.changed() => {
                let _ = send_close(&mut dst, CloseCode::Away, "server draining").await;
                break;
            }
        }
    }
    let _ = dst.close().await;
    stop.notify_waiters();
}

async fn send_close(
    dst: &mut FrameSink,
    code: CloseCode,
    reason: &'static str,
) -> Result<(), WsError> {
    dst.send(Message::Close(Some(CloseFrame {
        code,
        reason: reason.into(),
    })))
    .await
}
