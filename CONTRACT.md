# Fantastic Relay — wire contract (kernel v1)

The relay is a **kernel**: each connection is a `peer_proxy` agent, addressed by
its GUID. This is the contract a connecting kernel (the canvas `relay-connector`)
targets.

## 1. Connect

```
wss://<host>/<GUID>
  Sec-WebSocket-Protocol: fantastic.relay.v1     (required)
  X-Fantastic-Auth: <credential>                 (the group password, today)
```

- **GUID** = the connecting kernel's self-asserted id (path component). It must be
  **unique** — a second live connection with the same GUID is **rejected** at the
  handshake (the existing one is kept).
- **Auth** is connection-level, checked once at upgrade, via the configured ingress
  rule (`password` today; `certificate` later). Bad/missing credential ⇒ the
  upgrade is refused (HTTP 4xx, no socket).
- On success the relay spawns `peer_proxy(id=GUID)` and echoes the subprotocol.

## 2. Frames (JSON text)

Client → relay:
| type | fields | meaning |
|---|---|---|
| `call` | `id`, `target`, `payload` | request to `target`; correlated `reply` comes back |
| `send` | `target`, `payload` | fire-and-forget to `target` |
| `watch` | `target` | subscribe to a target's events (e.g. `relay`) |
| `unwatch` | `target` | unsubscribe |

Relay → client:
| type | fields | meaning |
|---|---|---|
| `reply` | `id`, `data` | the result of a `call` |
| `event` | `source`, `payload` | a message routed/forwarded to you |

- **`target: "relay"`** addresses the directory/router (see §3) — `call` is
  reply-correlated.
- **`target: <peer GUID>`** routes to that peer through one in-kernel hop; it
  arrives on the peer's socket as `{type:"event", source:<your GUID>, payload}`.

## 3. Directory (`relay`)

`call` `relay` with `{type:"list_peers"}` → `{peers:[{guid,status,last_seen,since}]}`.

- **`status`** ∈ `green` (seen within the keepalive window) | `yellow` (stale) |
  `red` (past the evict TTL, being reaped).
- `watch` `relay` to receive live `{type:"event", source:"relay", payload:{type:
  "peer_joined"|"peer_left"|"peer_evicted", guid}}` — the orchestration app's
  green/yellow/red button feed.
- `call` `relay` `{type:"evict", guid}` force-disconnects a peer.

## 4. Liveness

- Any inbound frame refreshes the peer's `last_seen`. A peer silent past the evict
  TTL is `delete_agent`'d → its socket closes → `peer_evicted` fires.
- A CDN/edge in front of the relay may close idle WS (~100s); the connecting
  kernel should send a periodic frame to stay green (the relay just forwards).

## 5. Trust

The relay **sees frame envelopes** (it routes by `target`) — it is not opaque.
Payload confidentiality, if wanted, is the endpoints' own concern (encrypt
`payload`); the relay is unaffected. One relay-kernel = one user (isolation by
instance).
