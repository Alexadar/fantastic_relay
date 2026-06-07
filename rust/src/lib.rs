//! Fantastic Relay — data-plane router (library root).
//!
//! A dumb, zero-trust pipe: authenticate identity → pair sockets → forward
//! OPAQUE frames → meter. It never speaks the Fantastic kernel protocol and
//! never inspects payloads. See `README.md` and `CONTRACT.md`.

pub mod auth;
pub mod config;
pub mod error;
pub mod forward;
pub mod issuer;
pub mod meter;
pub mod rendezvous;
pub mod ws;
