# Fantastic Relay — Rust router (`rust/`)

The reference / hosted-tier implementation: a dumb, zero-trust opaque-frame
WebSocket relay — authenticate → pair by `(tenant, rendezvous)` → forward
**opaque** frames → meter. See the root [`README.md`](../README.md) and the wire
[`CONTRACT.md`](../CONTRACT.md). The Swift port in [`../swift`](../swift) mirrors
this 1:1 and is held equivalent by [`../conformance`](../conformance).

## Layout

- `src/` — `auth`, `rendezvous`, `forward`, `meter`, `ws`, `config`, `error`, `lib`.
- Binaries: **`fantastic-router`** (the relay), **`relay-probe`** (a WS test client).
- `tests/relay_pairing.rs` — integration tests (pair + opaque round-trip + negatives).

## Build & test

```sh
cd rust
cargo build --release          # binary: target/release/fantastic-router
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test
```

## Run

Env-driven (see [`src/config.rs`](src/config.rs) for the full set):

```sh
ROUTER_CONTROL_PLANE_PUBKEY=<base64-ed25519> ROUTER_E2E_ASSERTED=true \
  ROUTER_LISTEN_ADDR=127.0.0.1:9443 ./target/release/fantastic-router
```

## Embed

The `fantastic_router` library exposes two entry points (matched by the Swift
`RelayServer`):

- `ws::serve(config, …)` — blocking; used by the CLI.
- `ws::start(config, …) -> ws::ServerHandle` — non-blocking; returns the bound
  address + an async `shutdown()` for in-process supervision.
