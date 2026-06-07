//! The two halves of the token contract agree: a password-gated `Issuer` mints a
//! token the relay's `Ed25519Verifier` accepts.

use ed25519_dalek::SigningKey;

use fantastic_router::auth::{Ed25519Verifier, TokenVerifier};
use fantastic_router::config::Config;
use fantastic_router::issuer::{Issuer, PasswordProvider};

fn setup() -> (Issuer, Ed25519Verifier) {
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).unwrap();
    let issuer = Issuer::new(SigningKey::from_bytes(&seed), "fantastic.relay", 60)
        .with_provider(Box::new(PasswordProvider::new("hunter2", "t1")));

    let config = Config {
        listen_addr: "127.0.0.1:0".into(),
        control_plane_pubkey_b64: Some(issuer.public_key_b64()),
        control_plane_pubkey_next_b64: None,
        audience: "fantastic.relay".into(),
        pair_timeout_secs: 30,
        max_frame_bytes: 16 << 20,
        max_session_bytes: 1 << 30,
        max_conns_global: 100,
        max_conns_per_ip: 100,
        max_waiting_global: 100,
        max_waiting_per_tenant: 100,
        token_max_lifetime_secs: 60,
        heartbeat_secs: 60,
    };
    let verifier = Ed25519Verifier::from_config(&config).unwrap();
    (issuer, verifier)
}

#[test]
fn issue_then_verify_roundtrip() {
    let (issuer, verifier) = setup();
    let token = issuer.issue("password", "hunter2", "A", "B", "rv").unwrap();
    let claims = verifier
        .verify(&token)
        .expect("verify should accept an issued token");
    assert_eq!(claims.tenant_id, "t1");
    assert_eq!(claims.peer_id, "A");
    assert_eq!(claims.partner_peer_id, "B");
    assert_eq!(claims.rendezvous, "rv");
}

#[test]
fn bad_password_rejected() {
    let (issuer, _v) = setup();
    assert!(issuer.issue("password", "wrong", "A", "B", "rv").is_err());
}

#[test]
fn unknown_provider_rejected() {
    let (issuer, _v) = setup();
    assert!(issuer.issue("apple", "hunter2", "A", "B", "rv").is_err());
}
