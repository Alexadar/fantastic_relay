//! Authentication seam.
//!
//! The router does NOT mint tokens and holds NO private key. It verifies a
//! token signed by the control plane and extracts the claims it needs to tag
//! and pair the connection. A forged token fails verification.
//!
//! Token wire form: `<b64url-nopad(claims_json)>.<b64url-nopad(ed25519_sig)>`
//! where the signature is over the raw `claims_json` bytes.

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use dashmap::DashMap;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config::Config;
use crate::error::RouterError;

/// Allowable clock skew (seconds) for `iat`/`nbf` checks.
const CLOCK_SKEW_SECS: u64 = 5;

/// What the router learns from a valid token. Nothing here grants access to
/// payload content — confidentiality is the endpoints' E2E job.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Claims {
    /// Billing/identity tenant. The meter counts bytes against this.
    pub tenant_id: String,
    /// The connecting device's public-key identity (opaque to routing).
    pub peer_id: String,
    /// Rendezvous id — the paired leg presents the same value.
    pub rendezvous: String,
    /// Expected counterpart `peer_id`. When non-empty on either leg, the relay
    /// requires it to match the other's `peer_id` (anti-hijack, pre-E2E).
    #[serde(default)]
    pub partner_peer_id: String,
    /// Audience — must equal this relay's id.
    #[serde(default)]
    pub aud: String,
    /// Issued-at (unix seconds).
    #[serde(default)]
    pub iat: u64,
    /// Not-before (unix seconds).
    #[serde(default)]
    pub nbf: u64,
    /// Expiry (unix seconds).
    pub exp: u64,
    /// Unique token id — single-use within validity.
    #[serde(default)]
    pub jti: String,
}

/// Pluggable verifier seam. Swap the impl (JWS/JWT, remote JWKS…) without
/// touching the forwarding core.
pub trait TokenVerifier: Send + Sync {
    fn verify(&self, token: &str) -> Result<Claims, RouterError>;
}

/// Default impl: detached Ed25519 over base64url JSON claims.
pub struct Ed25519Verifier {
    keys: Vec<VerifyingKey>,
    audience: String,
    token_max_lifetime_secs: u64,
    /// Single-use jti cache → expiry (unix secs); pruned lazily.
    seen_jti: DashMap<String, u64>,
}

fn decode_key(b64: &str) -> Result<VerifyingKey, RouterError> {
    let raw = STANDARD.decode(b64.trim()).map_err(|e| {
        RouterError::Config(format!("control-plane pubkey is not valid base64: {e}"))
    })?;
    let bytes: [u8; 32] = raw
        .as_slice()
        .try_into()
        .map_err(|_| RouterError::Config("control-plane pubkey must be 32 bytes".into()))?;
    VerifyingKey::from_bytes(&bytes)
        .map_err(|e| RouterError::Config(format!("control-plane pubkey is not on-curve: {e}")))
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Ed25519Verifier {
    pub fn from_config(config: &Config) -> Result<Self, RouterError> {
        let mut keys = Vec::new();
        if let Some(k) = &config.control_plane_pubkey_b64 {
            keys.push(decode_key(k)?);
        }
        if let Some(k) = &config.control_plane_pubkey_next_b64 {
            keys.push(decode_key(k)?);
        }
        if keys.is_empty() {
            return Err(RouterError::Config(
                "no control-plane pubkey configured".into(),
            ));
        }
        Ok(Self {
            keys,
            audience: config.audience.clone(),
            token_max_lifetime_secs: config.token_max_lifetime_secs,
            seen_jti: DashMap::new(),
        })
    }

    fn check_replay(&self, claims: &Claims) {
        if claims.jti.is_empty() {
            return;
        }
        // Opportunistic prune so the cache can't grow unbounded.
        if self.seen_jti.len() > 100_000 {
            let now = now_unix();
            self.seen_jti.retain(|_, exp| *exp > now);
        }
        self.seen_jti.insert(claims.jti.clone(), claims.exp);
    }
}

impl TokenVerifier for Ed25519Verifier {
    fn verify(&self, token: &str) -> Result<Claims, RouterError> {
        let (payload_b64, sig_b64) = match token.split_once('.') {
            Some((p, s)) => (p, Some(s)),
            None => (token, None),
        };
        let payload = URL_SAFE_NO_PAD
            .decode(payload_b64)
            .map_err(|_| RouterError::Auth("malformed token".into()))?;
        let claims: Claims = serde_json::from_slice(&payload)
            .map_err(|_| RouterError::Auth("malformed claims".into()))?;

        // Signature (detached, over the raw claims_json bytes), verify_strict.
        let sig_bytes = URL_SAFE_NO_PAD
            .decode(sig_b64.ok_or_else(|| RouterError::Auth("token missing signature".into()))?)
            .map_err(|_| RouterError::Auth("malformed signature".into()))?;
        let signature = Signature::from_slice(&sig_bytes)
            .map_err(|_| RouterError::Auth("malformed signature".into()))?;
        let ok = self
            .keys
            .iter()
            .any(|k| k.verify_strict(&payload, &signature).is_ok());
        if !ok {
            return Err(RouterError::Auth("bad signature".into()));
        }

        // Temporal + audience + lifetime checks.
        let now = now_unix();
        if claims.exp <= now {
            return Err(RouterError::Auth("expired".into()));
        }
        if claims.nbf > now + CLOCK_SKEW_SECS {
            return Err(RouterError::Auth("not yet valid".into()));
        }
        if claims.iat > now + CLOCK_SKEW_SECS {
            return Err(RouterError::Auth("issued in the future".into()));
        }
        if claims.iat != 0 && claims.exp.saturating_sub(claims.iat) > self.token_max_lifetime_secs {
            return Err(RouterError::Auth("token lifetime too long".into()));
        }
        if claims.aud != self.audience {
            return Err(RouterError::Auth("wrong audience".into()));
        }
        if !claims.jti.is_empty() && self.seen_jti.contains_key(&claims.jti) {
            return Err(RouterError::Auth("token replayed".into()));
        }
        if claims.tenant_id.is_empty() || claims.peer_id.is_empty() || claims.rendezvous.is_empty()
        {
            return Err(RouterError::Auth("incomplete claims".into()));
        }
        self.check_replay(&claims);
        Ok(claims)
    }
}
