# Fantastic Relay.app (operator-side macOS app)

A menu-bar + dashboard macOS app that **runs the relay** ([`RelayCore`](../swift),
embedded in-process), acts as the **control plane** (holds the Ed25519 signing
key + password, in the Keychain), and **runs a pre-configured cloudflared named
tunnel** so your devices can reach it.

Unsandboxed **Developer-ID** (it binds a loopback socket and spawns `cloudflared`)
— **not** Mac App Store. AGPL-3.0-or-later, same family as the relay.

> Alpha / concept. Distribution (sign + notarize) and a stable end-to-end pair
> against a real client are not wired here yet — see *Status* below.

## Build & run

```sh
brew install xcodegen cloudflared    # one-time
make run                             # xcodegen generate → xcodebuild → open
```

The app lives in the **menu bar** (no Dock icon). Click it for status / Start /
Stop / Copy URL, or open the dashboard for setup + the pairing handoff.

## One-time tunnel setup (you do this once, outside the app)

The app only **runs** a named tunnel — it never drives `login`/`create`/`route`.

```sh
cloudflared login
cloudflared tunnel create my-relay
# Map your hostname → the relay's loopback port (must match the app's Listen port):
cloudflared tunnel route dns my-relay relay.example.com
# ingress in ~/.cloudflared/config.yml:
#   ingress:
#     - hostname: relay.example.com
#       service: http://127.0.0.1:9443
#     - service: http_status:404
```

Then in the dashboard set **Named tunnel** = `my-relay`, **Public URL** =
`wss://relay.example.com`, **Listen port** = `9443`, set a **password**, and hit
**Start**.

## Pairing a device

Hand each of your devices three things from the dashboard:

- **Router URL** (`wss://…`)
- **Password** (the issuer credential)
- **Control-plane signing key** (secret — only to configure the device's
  `token_command`)

Each device self-mints its own short-lived (≤60s) token at connect time via its
`token_command` (running `fantastic-issue token` with the signing key + password)
— per the relay [`CONTRACT.md`](../CONTRACT.md) and the canvas `cloud_bridge`
client. The 100s idle-WS keepalive (Cloudflare Free) is the client's job (health
pings) — not the relay's.

## Status (v0)

- [x] Embeds `RelayCore`, runs the server in-process, injectable `Meter` → UI.
- [x] Keychain-backed signing key + password (fatal on persist failure — never
      silently regenerates the trust anchor).
- [x] Runs/stops the named cloudflared tunnel; graceful shutdown reaps it.
- [ ] Sign + notarize pipeline (mirror `fantastic_app/apple/scripts`).
- [ ] Verified pair against a real canvas/app client.
