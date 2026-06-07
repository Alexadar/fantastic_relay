# Conformance (`conformance/`)

One language-agnostic, black-box suite that both relay implementations must pass
— the anti-drift move for hosting two codebases ([`../rust`](../rust) and
[`../swift`](../swift)) behind one [`../CONTRACT.md`](../CONTRACT.md).

It boots a relay binary as a subprocess, points it at a fresh Ed25519 issuer
key, and drives real WebSocket clients through it.

## Run

```sh
cargo build --release --manifest-path conformance/Cargo.toml
# build both relays first (see ../rust and ../swift), then run against both:
./target/release/conformance \
  ../rust/target/release/fantastic-router \
  ../swift/.build/release/relayd
```

Exit code is non-zero if any scenario fails on any binary.

## Scenarios

`pair_and_forward` (Text + Binary verbatim) · `self_pair_rejected` ·
`partner_mismatch_rejected` · `bad_token_rejected` (401 pre-upgrade) ·
`ping_pong` (auto-reply, not cross-forwarded) · `pair_timeout`.

## Coverage split

- **Behaviour** (pairing, opaque forwarding, auth rejection, liveness) — this
  black-box runner, against both binaries.
- **Token-vector parity** (Ed25519 verify: valid accept; tampered / wrong-key /
  wrong-audience / expired / over-lifetime / replayed-jti reject) — each impl's
  own unit tests. Adversarial *signature* edge cases (non-canonical S,
  small-order points) may differ between `ed25519-dalek`'s `verify_strict` and
  swift-crypto; that divergence is documented, not gated.
