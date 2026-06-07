//! Runtime configuration — env-driven. NO secrets are baked in; the router
//! holds only the control plane's PUBLIC key, never a private one.

use std::str::FromStr;

use crate::error::RouterError;

/// The WebSocket subprotocol every relay client must offer (alongside the token).
pub const SUBPROTOCOL: &str = "fantastic.relay.v1";

#[derive(Clone)]
pub struct Config {
    /// Loopback listen address. A user-run tunnel (cloudflared) / managed proxy
    /// terminates TLS in front; the router speaks plain WS and is never exposed
    /// directly. e.g. `127.0.0.1:9443`.
    pub listen_addr: String,

    /// Base64 (std) Ed25519 public key of the control-plane token issuer
    /// (current). Public material only. Always required.
    pub control_plane_pubkey_b64: Option<String>,
    /// Optional NEXT issuer key, accepted during a rotation overlap window.
    pub control_plane_pubkey_next_b64: Option<String>,

    /// Expected token audience (`aud`) — this relay's id. Hard-rejected on
    /// mismatch.
    pub audience: String,

    /// When true (default), the router refuses to launch unless the operator
    /// asserts the endpoints are E2E-capable (`e2e_asserted`). When false, it
    /// launches with a loud plaintext warning. Until `cloud_bridge` ships
    /// end-to-end encryption, payloads are plaintext and a relay compromise
    /// leaks full content.
    pub require_e2e: bool,
    /// Operator assertion that the endpoints carry their own E2E layer.
    pub e2e_asserted: bool,

    /// Max seconds a half-open connection waits for its pair before timeout.
    pub pair_timeout_secs: u64,

    /// Max single WS message accepted from a peer (bytes). Endpoints open with
    /// 16 MiB (`max_size=2**24`); a smaller cap would sever legitimate chunked
    /// transfers mid-session with a 1009 close.
    pub max_frame_bytes: usize,

    /// Max bytes forwarded in one session before the relay closes it (1008).
    pub max_session_bytes: u64,

    /// Max concurrent connections globally / per source IP (pre-auth DoS guard).
    pub max_conns_global: usize,
    pub max_conns_per_ip: usize,

    /// Max concurrent UNPAIRED waiting slots globally / per tenant (anti slow-loris).
    pub max_waiting_global: usize,
    pub max_waiting_per_tenant: usize,

    /// Max accepted token lifetime (`exp - iat`) in seconds.
    pub token_max_lifetime_secs: u64,

    /// Usage Heartbeat interval (seconds) emitted during a live session.
    pub heartbeat_secs: u64,
}

fn env_or<T: FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_bool(key: &str, default: bool) -> bool {
    match std::env::var(key) {
        Ok(v) => matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        Err(_) => default,
    }
}

impl Config {
    pub fn from_env() -> Result<Self, RouterError> {
        let control_plane_pubkey_b64 = std::env::var("ROUTER_CONTROL_PLANE_PUBKEY").ok();
        if control_plane_pubkey_b64.is_none() {
            return Err(RouterError::Config(
                "ROUTER_CONTROL_PLANE_PUBKEY is required".into(),
            ));
        }

        Ok(Self {
            listen_addr: std::env::var("ROUTER_LISTEN_ADDR")
                .unwrap_or_else(|_| "127.0.0.1:9443".into()),
            control_plane_pubkey_b64,
            control_plane_pubkey_next_b64: std::env::var("ROUTER_CONTROL_PLANE_PUBKEY_NEXT").ok(),
            audience: std::env::var("ROUTER_AUDIENCE").unwrap_or_else(|_| "fantastic.relay".into()),
            require_e2e: env_bool("ROUTER_REQUIRE_E2E", true),
            e2e_asserted: env_bool("ROUTER_E2E_ASSERTED", false),
            pair_timeout_secs: env_or("ROUTER_PAIR_TIMEOUT_SECS", 30),
            max_frame_bytes: env_or("ROUTER_MAX_FRAME_BYTES", 16 << 20),
            max_session_bytes: env_or("ROUTER_MAX_SESSION_BYTES", 50u64 << 30), // 50 GiB
            max_conns_global: env_or("ROUTER_MAX_CONNS_GLOBAL", 4096),
            max_conns_per_ip: env_or("ROUTER_MAX_CONNS_PER_IP", 64),
            max_waiting_global: env_or("ROUTER_MAX_WAITING_GLOBAL", 2048),
            max_waiting_per_tenant: env_or("ROUTER_MAX_WAITING_PER_TENANT", 64),
            token_max_lifetime_secs: env_or("ROUTER_TOKEN_MAX_LIFETIME_SECS", 60),
            heartbeat_secs: env_or("ROUTER_HEARTBEAT_SECS", 60),
        })
    }
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never log key material verbatim.
        f.debug_struct("Config")
            .field("listen_addr", &self.listen_addr)
            .field(
                "control_plane_pubkey",
                &self.control_plane_pubkey_b64.as_ref().map(|_| "<redacted>"),
            )
            .field(
                "control_plane_pubkey_next",
                &self
                    .control_plane_pubkey_next_b64
                    .as_ref()
                    .map(|_| "<redacted>"),
            )
            .field("audience", &self.audience)
            .field("require_e2e", &self.require_e2e)
            .field("e2e_asserted", &self.e2e_asserted)
            .field("pair_timeout_secs", &self.pair_timeout_secs)
            .field("max_frame_bytes", &self.max_frame_bytes)
            .field("max_session_bytes", &self.max_session_bytes)
            .field("max_conns_global", &self.max_conns_global)
            .field("max_conns_per_ip", &self.max_conns_per_ip)
            .field("max_waiting_global", &self.max_waiting_global)
            .field("max_waiting_per_tenant", &self.max_waiting_per_tenant)
            .field("token_max_lifetime_secs", &self.token_max_lifetime_secs)
            .field("heartbeat_secs", &self.heartbeat_secs)
            .finish()
    }
}
