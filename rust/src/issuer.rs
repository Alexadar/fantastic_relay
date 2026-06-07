//! Control-plane token issuance — the signing counterpart to `auth::verify`.
//!
//! A pluggable `AuthProvider` (password first; Apple/Google later) gates minting
//! a short-lived Ed25519 relay token. This lives in the CONTROL PLANE (the app,
//! or the headless `fantastic-issue` CLI) and holds the signing PRIVATE key —
//! the relay daemon holds only the public key and verifies. Adding a provider
//! never changes the token format, so the relay is untouched.

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::auth::Claims;
use crate::error::RouterError;

/// Authenticates a credential and yields the tenant it maps to. Future Apple /
/// Google providers implement this beside `PasswordProvider`.
pub trait AuthProvider: Send + Sync {
    fn name(&self) -> &str;
    /// `Some(tenant_id)` on success, `None` on a bad credential.
    fn authenticate(&self, credential: &str) -> Option<String>;
}

/// First provider: a single shared password → a single tenant. Set in the UI
/// or, for headless machines, passed as a CLI/env value.
pub struct PasswordProvider {
    password: String,
    tenant_id: String,
}

impl PasswordProvider {
    pub fn new(password: impl Into<String>, tenant_id: impl Into<String>) -> Self {
        Self {
            password: password.into(),
            tenant_id: tenant_id.into(),
        }
    }
}

impl AuthProvider for PasswordProvider {
    fn name(&self) -> &str {
        "password"
    }
    fn authenticate(&self, credential: &str) -> Option<String> {
        if ct_eq(credential.as_bytes(), self.password.as_bytes()) {
            Some(self.tenant_id.clone())
        } else {
            None
        }
    }
}

/// Mints signed relay tokens after a provider authenticates the credential.
pub struct Issuer {
    signing: SigningKey,
    audience: String,
    token_ttl_secs: u64,
    providers: Vec<Box<dyn AuthProvider>>,
}

impl Issuer {
    pub fn new(signing: SigningKey, audience: impl Into<String>, token_ttl_secs: u64) -> Self {
        Self {
            signing,
            audience: audience.into(),
            token_ttl_secs,
            providers: Vec::new(),
        }
    }

    pub fn with_provider(mut self, provider: Box<dyn AuthProvider>) -> Self {
        self.providers.push(provider);
        self
    }

    /// Std-base64 of the public key — set this as the relay's
    /// `ROUTER_CONTROL_PLANE_PUBKEY`.
    pub fn public_key_b64(&self) -> String {
        STANDARD.encode(self.signing.verifying_key().to_bytes())
    }

    /// Authenticate `credential` against the named provider; on success mint a
    /// signed token for `(peer_id, partner_peer_id, rendezvous)`.
    pub fn issue(
        &self,
        provider: &str,
        credential: &str,
        peer_id: &str,
        partner_peer_id: &str,
        rendezvous: &str,
    ) -> Result<String, RouterError> {
        let p = self
            .providers
            .iter()
            .find(|p| p.name() == provider)
            .ok_or_else(|| RouterError::Auth(format!("unknown provider {provider:?}")))?;
        let tenant_id = p
            .authenticate(credential)
            .ok_or_else(|| RouterError::Auth("bad credential".into()))?;

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut nonce = [0u8; 12];
        let _ = getrandom::getrandom(&mut nonce);
        let claims = Claims {
            tenant_id,
            peer_id: peer_id.to_string(),
            rendezvous: rendezvous.to_string(),
            partner_peer_id: partner_peer_id.to_string(),
            aud: self.audience.clone(),
            iat: now,
            nbf: 0,
            exp: now + self.token_ttl_secs,
            jti: URL_SAFE_NO_PAD.encode(nonce),
        };
        let payload =
            serde_json::to_vec(&claims).map_err(|e| RouterError::Config(e.to_string()))?;
        let sig = self.signing.sign(&payload);
        Ok(format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(&payload),
            URL_SAFE_NO_PAD.encode(sig.to_bytes())
        ))
    }
}

/// Constant-time-ish equality (over equal-length inputs). Good enough for a
/// personal-tool password gate.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}
