//! fantastic-issue — headless control-plane token minter (for independent
//! machines + the e2e test). The app embeds the same `issuer` lib with a UI.
//!
//!   fantastic-issue keygen
//!     → prints a signing keypair (RELAY_SIGNING_KEY + ROUTER_CONTROL_PLANE_PUBKEY).
//!
//!   RELAY_SIGNING_KEY=<b64> RELAY_PASSWORD=<account-pw> \
//!     fantastic-issue token --password <pw> --peer A --partner B --rendezvous <id>
//!     → prints a relay token iff <pw> matches RELAY_PASSWORD.
//!
//! Env: RELAY_SIGNING_KEY, RELAY_PASSWORD (required for `token`);
//!      RELAY_TENANT (=t1), RELAY_AUDIENCE (=fantastic.relay), RELAY_TOKEN_TTL (=60).

use std::collections::HashMap;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use ed25519_dalek::SigningKey;

use fantastic_router::issuer::{Issuer, PasswordProvider};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (cmd, rest): (&str, &[String]) = match args.first() {
        Some(a) if a == "keygen" => ("keygen", &args[1..]),
        Some(a) if a == "token" => ("token", &args[1..]),
        _ => ("token", &args[..]),
    };
    match cmd {
        "keygen" => keygen(),
        "token" => token(&parse_flags(rest)),
        other => {
            eprintln!("unknown command {other:?}; use `keygen` or `token`");
            std::process::exit(2);
        }
    }
}

fn parse_flags(args: &[String]) -> HashMap<String, String> {
    let mut m = HashMap::new();
    let mut i = 0;
    while i < args.len() {
        if let Some(k) = args[i].strip_prefix("--") {
            m.insert(k.to_string(), args.get(i + 1).cloned().unwrap_or_default());
            i += 2;
        } else {
            i += 1;
        }
    }
    m
}

fn keygen() {
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).expect("getrandom");
    let sk = SigningKey::from_bytes(&seed);
    println!("# control-plane signing key (KEEP SECRET):");
    println!("RELAY_SIGNING_KEY={}", STANDARD.encode(seed));
    println!("# relay verifier key (set on the relay):");
    println!(
        "ROUTER_CONTROL_PLANE_PUBKEY={}",
        STANDARD.encode(sk.verifying_key().to_bytes())
    );
}

fn token(flags: &HashMap<String, String>) {
    let signing_b64 = flags
        .get("signing-key")
        .cloned()
        .or_else(|| std::env::var("RELAY_SIGNING_KEY").ok())
        .unwrap_or_else(|| die("missing --signing-key / RELAY_SIGNING_KEY"));
    let account_pw = std::env::var("RELAY_PASSWORD")
        .unwrap_or_else(|_| die("missing RELAY_PASSWORD (the control-plane password)"));
    let tenant = std::env::var("RELAY_TENANT").unwrap_or_else(|_| "t1".into());
    let audience = std::env::var("RELAY_AUDIENCE").unwrap_or_else(|_| "fantastic.relay".into());
    let ttl: u64 = std::env::var("RELAY_TOKEN_TTL")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60);

    let presented = flags.get("password").cloned().unwrap_or_default();
    let peer = req(flags, "peer");
    let partner = flags.get("partner").cloned().unwrap_or_default();
    let rendezvous = req(flags, "rendezvous");

    let seed: [u8; 32] = STANDARD
        .decode(signing_b64.trim())
        .ok()
        .and_then(|v| v.try_into().ok())
        .unwrap_or_else(|| die("RELAY_SIGNING_KEY must be base64 of 32 bytes"));
    let issuer = Issuer::new(SigningKey::from_bytes(&seed), audience, ttl)
        .with_provider(Box::new(PasswordProvider::new(account_pw, tenant)));

    match issuer.issue("password", &presented, &peer, &partner, &rendezvous) {
        Ok(token) => println!("{token}"),
        Err(e) => {
            eprintln!("issue failed: {e}");
            std::process::exit(1);
        }
    }
}

fn req(flags: &HashMap<String, String>, key: &str) -> String {
    flags
        .get(key)
        .cloned()
        .unwrap_or_else(|| die(&format!("missing --{key}")))
}

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(2);
}
