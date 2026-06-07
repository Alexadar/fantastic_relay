# Relay wire contract (v1)

The published contract a client (`cloud_bridge`, or any app) must implement to
use the relay router. The router never speaks the Fantastic kernel protocol — it
authenticates, pairs, and forwards **opaque** frames. Everything below is what a
client puts *on the wire*; the kernel `call`/`reply` JSON rides **inside** the
(end-to-end encrypted) payload and is invisible to the relay.

## 1. Connect

- **Router URL**: the app lets the user enter it, e.g.
  `wss://aisixteen.com/fantastic/cloud/router` (managed) or
  `wss://<your-tunnel-host>/…` (self-hosted). Behind the URL the router speaks
  plain WS on `127.0.0.1:9443`; a tunnel/proxy terminates TLS.
- **Both peers dial OUT** to the same router URL — no inbound ports on devices.

## 2. Authenticate (at the WS handshake)

The client offers the subprotocol **and** the token as a second protocol value:

```
Sec-WebSocket-Protocol: fantastic.relay.v1, <base64url-nopad(token)>
```

- The router verifies the token; on success it echoes the single accepted
  subprotocol `fantastic.relay.v1`.
- **Strict**: a missing/invalid token ⇒ **HTTP 401 before the upgrade** — no
  WebSocket is established, no pairing slot is allocated.

### Token

`<base64url-nopad(claims_json)>.<base64url-nopad(ed25519_sig)>`

The signature is a detached Ed25519 signature over the **raw `claims_json`
bytes**, verifiable with the control plane's published public key. (Dev mode,
`ROUTER_REQUIRE_AUTH=false`, accepts the claims segment alone, unsigned — for
`relay-probe`/testing only.)

### Claims

| field | type | meaning |
|---|---|---|
| `tenant_id` | string | billing/identity tenant; the meter counts bytes against it |
| `peer_id` | string | this device's public-key identity (opaque to routing) |
| `rendezvous` | string | the shared session id; the paired leg presents the same value |
| `partner_peer_id` | string | expected counterpart `peer_id` (binds the pair); may be empty |
| `aud` | string | must equal the relay's audience (`fantastic.relay` by default) |
| `iat`, `nbf`, `exp` | uint (unix s) | issued-at / not-before / expiry |
| `jti` | string | unique token id — single-use within validity |

Issuer constraints the router enforces (strict mode): `verify_strict` signature,
`aud` match, `nbf ≤ now`, `iat ≤ now`, `exp > now`, `exp − iat ≤ 60 s`, `jti`
unused. The control plane issues **both** peers a token carrying the **same**
`rendezvous`.

## 3. Pairing

- Pairing key is the tuple **`(tenant_id, rendezvous)`**. The two legs MUST have
  **distinct `peer_id`** (self-pair is rejected).
- If `partner_peer_id` is set on either leg, it must match the other's `peer_id`.
- **Single-use**: the first arrival parks; the second matches and the slot is
  consumed. A third party presenting the same rendezvous after pairing is not
  spliced in.
- A leg that never gets a partner is closed after the pair timeout (default 30 s).
- Rejections close with code **1008** (policy): `self-pair`, `partner-mismatch`,
  `waiting-cap`.

## 4. Forwarding (opaque)

- Once paired, **Binary and Text frames are forwarded verbatim**, opcode
  preserved, never inspected. (The kernel sends Text/JSON today; Binary is
  headroom.)
- **Ping/Pong are not cross-forwarded** — each hop's WebSocket auto-replies to
  pings locally. Send your own keepalive as an ordinary **data** frame (below).
- A **Close** is forwarded, then that direction half-closes.
- **Limits**: max message size **16 MiB** (matches the kernel's `max_size`);
  oversize ⇒ close **1009**. Per-session / per-tenant byte + rate caps ⇒ close
  **1008**.

## 5. Client obligations (E2E + heartbeat) — REQUIRED for production

1. **End-to-end encryption.** The relay sees only ciphertext **iff the endpoints
   encrypt**. Clients MUST run a peer-to-peer end-to-end encryption layer — e.g.
   **TLS 1.3 mutual auth** (self-signed certs pinned to the device identity keys)
   or Noise — bound to the `peer_id` identities, so a relay/tunnel compromise
   leaks only ciphertext. **The relay is agnostic to the mechanism**: it forwards
   the encrypted bytes as opaque frames and never inspects them. Until this ships,
   the router runs in a plaintext, non-production posture (`ROUTER_REQUIRE_E2E`).
2. **Application heartbeat.** A CDN/edge in front of the relay may close idle
   WebSockets (~100 s). Clients MUST emit an ordinary data frame every 30–60 s
   (the relay forwards it verbatim) to keep a quiet session alive — a WS Ping is
   NOT sufficient (it isn't forwarded).

## Close codes

| code | meaning |
|---|---|
| 1008 | policy: pairing rejected / byte or rate cap exceeded |
| 1009 | message too large (> 16 MiB) |
| 1001 | server draining (graceful shutdown) |
