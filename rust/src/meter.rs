//! Metering seam.
//!
//! Counts ciphertext bytes + connection-minutes per tenant and emits usage
//! events — knows *who* + *how much*, never *what*. `StdoutMeter` logs one JSON
//! line per event; a durable sink (HTTP/NATS) can slot in behind the `Meter`
//! trait later. The event SHAPE (stable `event_id`, monotonic `seq`, periodic
//! `Heartbeat`) is fixed now so a downstream ledger can dedupe + order, and a
//! crash loses at most one heartbeat window.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use sha2::{Digest, Sha256};

/// Why an event was emitted.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageKind {
    /// Final tally when a session ends.
    SessionClose,
    /// Periodic mid-session tally (crash-resilience for billing).
    Heartbeat,
}

/// One usage record. `session_id` is a SALTED hash of the rendezvous — the raw
/// rendezvous id is never logged.
#[derive(Clone, Debug, Serialize)]
pub struct UsageEvent {
    pub event_id: String,
    pub tenant_id: String,
    pub session_id: String,
    pub seq: u64,
    pub bytes_a_to_b: u64,
    pub bytes_b_to_a: u64,
    pub conn_seconds: u64,
    pub ts_unix: u64,
    pub kind: UsageKind,
}

impl UsageEvent {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        kind: UsageKind,
        tenant_id: &str,
        session_id: &str,
        seq: u64,
        bytes_a_to_b: u64,
        bytes_b_to_a: u64,
        conn_seconds: u64,
    ) -> Self {
        Self {
            event_id: uuid::Uuid::new_v4().to_string(),
            tenant_id: tenant_id.to_string(),
            session_id: session_id.to_string(),
            seq,
            bytes_a_to_b,
            bytes_b_to_a,
            conn_seconds,
            ts_unix: now_unix(),
            kind,
        }
    }
}

/// Pluggable metering sink.
pub trait Meter: Send + Sync {
    fn record(&self, event: &UsageEvent);
}

/// Default impl: one JSON line per event on the `usage` tracing target.
pub struct StdoutMeter {
    /// Per-process random salt so logged `session_id`s can't be reversed to the
    /// raw rendezvous id (which would aid a hijack race if logs leak).
    salt: [u8; 16],
}

impl StdoutMeter {
    pub fn new() -> Self {
        let mut salt = [0u8; 16];
        // Best-effort; getrandom only fails on exotic platforms. A zero salt
        // would merely make session_ids predictable, not unsafe.
        let _ = getrandom::getrandom(&mut salt);
        Self { salt }
    }

    /// Salted, opaque session id derived from the rendezvous. Stable for the
    /// life of the process; never reveals the raw rendezvous.
    pub fn session_id(&self, rendezvous: &str) -> String {
        let mut h = Sha256::new();
        h.update(self.salt);
        h.update(rendezvous.as_bytes());
        let digest = h.finalize();
        let mut out = String::with_capacity(16);
        for b in &digest[..8] {
            use std::fmt::Write;
            let _ = write!(out, "{b:02x}");
        }
        out
    }
}

impl Default for StdoutMeter {
    fn default() -> Self {
        Self::new()
    }
}

impl Meter for StdoutMeter {
    fn record(&self, event: &UsageEvent) {
        if let Ok(json) = serde_json::to_string(event) {
            tracing::info!(target: "usage", "{json}");
        }
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_id_is_stable_and_distinguishes_rendezvous() {
        let m = StdoutMeter::new();
        assert_eq!(m.session_id("rv-a"), m.session_id("rv-a"));
        assert_ne!(m.session_id("rv-a"), m.session_id("rv-b"));
        assert_eq!(m.session_id("rv-a").len(), 16);
    }

    #[test]
    fn usage_event_serializes_snake_case() {
        let e = UsageEvent::new(UsageKind::SessionClose, "t1", "sid", 3, 10, 20, 5);
        let j = serde_json::to_value(&e).unwrap();
        assert_eq!(j["tenant_id"], "t1");
        assert_eq!(j["session_id"], "sid");
        assert_eq!(j["seq"], 3);
        assert_eq!(j["bytes_a_to_b"], 10);
        assert_eq!(j["bytes_b_to_a"], 20);
        assert_eq!(j["conn_seconds"], 5);
        assert_eq!(j["kind"], "session_close");
        assert!(!j["event_id"].as_str().unwrap().is_empty());
    }

    #[test]
    fn heartbeat_kind_serializes() {
        let e = UsageEvent::new(UsageKind::Heartbeat, "t", "s", 0, 0, 0, 0);
        assert_eq!(serde_json::to_value(&e).unwrap()["kind"], "heartbeat");
    }
}
