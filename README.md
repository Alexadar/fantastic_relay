# Aisixteen Fantastic — Relay (data-plane router)

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Spellcheck](https://github.com/Alexadar/fantastic_relay/actions/workflows/spellcheck.yml/badge.svg)](https://github.com/Alexadar/fantastic_relay/actions/workflows/spellcheck.yml)
![status: alpha](https://img.shields.io/badge/status-alpha-orange)

A **dumb, zero-trust opaque-frame WebSocket relay** for the
[Aisixteen Fantastic](https://github.com/Alexadar/fantastic_canvas) family. It
lets any device reach any other through NAT/firewalls by **pairing two
outbound connections and forwarding opaque bytes between them** — nothing more.

It is deliberately **not** a Fantastic kernel. A kernel's `send`/`reflect` are
protocol-floor verbs that would expose a local agent namespace to every
connected peer. The relay's invariant is the opposite: a peer can address
**only its paired peer, and only after auth**. So the relay holds no content,
no long-lived secrets, and no vault — it does three things and stops:

> **authenticate identity → pair sockets → forward opaque frames** (and meter).

## How it fits

| Layer | Where | Does |
|---|---|---|
| `cloud_bridge` transport | **kernel side** ([fantastic_canvas](https://github.com/Alexadar/fantastic_canvas), future) | dials a **router URL**, presents a token, runs the peer↔peer **E2E handshake**, tunnels encrypted frames |
| **this relay router** | here | verify token → pair by `(tenant, rendezvous)` → forward **opaque** bytes → meter |
| provisioning / hosting | elsewhere | stand up an always-on managed host if/when wanted — out of scope here |

**Apps enter a router URL.** A client points at whichever relay it wants —
`wss://<your-own-tunnel>/…` (self-hosted, free) or a managed/paid URL. Same
binary either way. That URL field *is* the self-hosted-vs-managed switch.

## ⚠ Security model — read this

The relay moves **opaque** frames and never inspects payloads. Confidentiality
is the **endpoints'** job (end-to-end encryption between the two devices), not
the relay's. Concretely:

- The relay (and any tunnel/CDN in front of it) sees **metadata** — *who*
  (tenant, peer id), *how much*, *when* — but never *what*, **once the endpoints
  encrypt end-to-end**.
- A forged route simply **fails the endpoints' E2E handshake** → an impostor
  can't prove it holds the peer's key, so relay routing honesty is irrelevant to
  security; forgery degrades to a rate-limited availability nuisance.

**E2E is a prerequisite, not yet shipped.** Today's kernel `kernel_bridge`
transport sends **plaintext JSON** — there is no peer end-to-end layer yet
(that lands in `cloud_bridge`). Until it does, payloads are plaintext and a
relay compromise leaks full content. The router therefore ships a
`ROUTER_REQUIRE_E2E` launch-gate: in production it **refuses to launch** unless
the operator asserts the endpoints are E2E-capable; otherwise it emits a loud
plaintext warning. **Do not carry production traffic before the endpoint Noise
layer + application heartbeat land.**

Strict auth: a missing or invalid token **aborts the WebSocket handshake
pre-upgrade (HTTP 401)** — no socket, no pairing slot.

## Architecture

```
device A (cloud_bridge) ─┐   user enters router URL
                         ├─ WSS ─►  [ user-run tunnel, dials OUT ] ─┐
device B (cloud_bridge) ─┘   (cloudflared / managed proxy)         ▼
                                          fantastic-router (127.0.0.1:9443, plain WS)
                       subprotocol-auth → (tenant, rendezvous) pair → opaque forward → meter
```

The tunnel dials **out** → no inbound ports, no public origin to attack. The
router is byte-identical whether fronted by a self-hosted tunnel or a managed
proxy — proof the dumb-pipe design is deployment-agnostic.

## Build & run

```sh
cd router
cargo build --release            # binary: target/release/fantastic-router
ROUTER_CONTROL_PLANE_PUBKEY=<base64-ed25519-pubkey> \
  ROUTER_LISTEN_ADDR=127.0.0.1:9443 \
  cargo run --release --bin fantastic-router
```

Key environment variables (see [`router/src/config.rs`](router/src/config.rs)):

| Var | Default | Meaning |
|---|---|---|
| `ROUTER_LISTEN_ADDR` | `127.0.0.1:9443` | loopback bind; a tunnel/proxy terminates TLS in front |
| `ROUTER_CONTROL_PLANE_PUBKEY` | — | base64 Ed25519 public key of the token issuer (required when auth on) |
| `ROUTER_REQUIRE_AUTH` | `true` | strict: missing/invalid token → 401 pre-upgrade. `false` = dev-only |
| `ROUTER_REQUIRE_E2E` | `true` | refuse to launch in prod unless `ROUTER_E2E_ASSERTED=true` |
| `ROUTER_AUDIENCE` | `fantastic.relay` | expected token `aud` |
| `ROUTER_MAX_FRAME_BYTES` | `16777216` | 16 MiB — matches the endpoints' max message size |
| `ROUTER_PAIR_TIMEOUT_SECS` | `30` | how long a half-open connection waits for its pair |

A standalone `relay-probe` binary (a minimal WS test client) lets you exercise
pairing without the real endpoint transport — run two probes (with
`ROUTER_REQUIRE_AUTH=false`) and watch opaque frames round-trip.

## Expose via your own tunnel

The router listens on loopback; you expose it with a tunnel **you** run (no
inbound ports, no certs to manage):

```sh
# one-time: authenticate + create a named tunnel, then route a hostname/path to the router
cloudflared tunnel login
cloudflared tunnel create fantastic-relay
# map https://<your-host>/fantastic/cloud/router → http://127.0.0.1:9443 (WebSockets pass through)
cloudflared tunnel run --url http://127.0.0.1:9443 fantastic-relay
```

Then point apps at the resulting URL. Standing up an always-on **managed** host
(and its origin TLS hardening) is a separate concern handled elsewhere — this
repo ships only the router and docs.

## Wire contract

The token format, subprotocol auth, `(tenant, rendezvous)` addressing, and the
opaque-frame framing are the published contract that `cloud_bridge` (and any
client) targets — see [`router/CONTRACT.md`](router/CONTRACT.md).

## Status

Alpha. The router (auth → pairing → opaque forward → metering) is the focus;
`cloud_bridge` (the kernel-side transport that adds Noise E2E, peer-approval,
the application heartbeat, and the router-URL field) follows in
[fantastic_canvas](https://github.com/Alexadar/fantastic_canvas) once this router
reaches minimal maturity.

## License & trademark

**AGPL-3.0-or-later** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright © 2026 Koreniuk Oleksandr (aisixteen).

Why AGPL: we want the relay auditable and forks open, and §13 covers
network/SaaS use — a competitor can't fork it into a closed managed service. As
the sole copyright holder we still offer managed hosting and, for terms without
AGPL, a commercial license — contact `kvazis@gmail.com`.

This relay is **not** an independent project — it is by the same author as the
Aisixteen Fantastic [kernel](https://github.com/Alexadar/fantastic_canvas) and
[Apple client](https://github.com/Alexadar/fantastic_app), forming one product
family under one license. It **interoperates** with the kernel only over the
wire protocol (opaque frames); it does not vendor or link their source.

**Trademark carve-out (AGPL §7):** "Aisixteen Fantastic" and the **AISIXTEEN**
word mark (USPTO reg. 7,238,635) are trademarks of AISIXTEEN. The license covers
the code only — a fork must ship under a different name.
