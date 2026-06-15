# Fantastic Relay

A **relay-kernel** for the Aisixteen Fantastic family: connected kernels become
**agents**, so the relay is an addressable router with a live directory — not a
dumb pipe. Built **on the canvas kernel as a library** (no vendored code).

- **Directory** — every connected kernel is a `peer_proxy` agent; the flat agent
  registry *is* the directory. GUIDs are unique (duplicate → rejected).
- **Router** — A reaches B by GUID through one in-kernel hop (`kernel.send`), so a
  pair is **2 sockets + 1 hop**, not 3 sockets.
- **Health** — each peer's `last_seen` drives **green / yellow / red**; a silent
  peer past the TTL is evicted. `list_peers` + `watch` feed an orchestration app's
  status buttons.
- **Auth** — a pluggable ingress boundary; **`password`** (shared group token) is
  the first rule, **`certificate`** is a left-open seam.
- **Isolation by instance** — one relay-kernel **per user**; a standalone
  supervisor spawns them (one now, a fleet for cloud). No shared multi-tenant table.

The relay **sees frames** (it routes by envelope); it is not an opaque pipe. If a
client wants payload confidentiality it encrypts its own payloads — the relay is
unaffected.

## Layout

```
relaykernel/        Swift package (depends on ../../fantastic_canvas/swift as a lib)
  Sources/RelayKernel   engine + bundles (relay_router, peer_proxy) + NIO inbound + auth
  Sources/relayd        headless daemon
  Sources/relay-supervisor   standalone per-user spawner (alpha stub)
apple/              the operator macOS app (menu-bar + dashboard) embedding RelayKernel
```

## Run (headless)

```sh
cd relaykernel
FANTASTIC_GROUP_TOKEN=<your-password> RELAY_LISTEN_ADDR=127.0.0.1:9443 \
  swift run relayd
```

Then front it with your cloudflared **named tunnel** (`relay.aisixteen.com` →
`http://127.0.0.1:9443`) — see [`docs/RUNNING.md`](docs/RUNNING.md). A kernel
connects with:

```
wss://relay.aisixteen.com/<GUID>      Sec-WebSocket-Protocol: fantastic.relay.v1
                                      X-Fantastic-Auth: <group password>
```

Wire protocol + status model: [`CONTRACT.md`](CONTRACT.md).

## Build & test

```sh
cd relaykernel && swift build && swift test    # engine, NIO surface, auth, routing, directory, eviction
cd apple && make build                         # the operator app
```

## Status

Alpha. The relay-kernel (directory + router + health + password auth) is done and
tested headless. Client **relay-connector agents** land next in
[fantastic_canvas](https://github.com/Alexadar/fantastic_canvas) / the app — see
`fantastic_canvas/tmp/relay_connector_agents.md`.

## License & trademark

AGPL-3.0-or-later (the app links the AGPL canvas kernel). See [`LICENSE`](LICENSE)
+ [`NOTICE`](NOTICE).
