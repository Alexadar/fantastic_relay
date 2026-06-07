//! Fantastic Relay router binary — a thin wrapper over the library.
//!
//! Bootstrap wiring only: load config → build the pluggable seams (verifier /
//! rendezvous / meter) → serve. The real work lives in the library modules.

use std::sync::Arc;

use fantastic_router::auth::Ed25519Verifier;
use fantastic_router::config::Config;
use fantastic_router::meter::StdoutMeter;
use fantastic_router::rendezvous::InMemoryRendezvous;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let config = Config::from_env()?;
    tracing::info!(?config, "fantastic-router starting");

    // Pluggable seams — swap these impls without touching the forwarding core.
    let verifier = Arc::new(Ed25519Verifier::from_config(&config)?);
    let rendezvous = Arc::new(InMemoryRendezvous::from_config(&config));
    let meter = Arc::new(StdoutMeter::new());

    fantastic_router::ws::serve(config, verifier, rendezvous, meter).await
}
