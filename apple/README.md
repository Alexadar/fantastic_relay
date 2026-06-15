# Fantastic Relay.app (operator-side macOS app)

A menu-bar + dashboard macOS app that **runs the relay-kernel**
([`RelayKernel`](../relaykernel), embedded in-process), holds the **group
password** (Keychain), and **runs a pre-configured cloudflared named tunnel** so
your kernels can reach it. The dashboard shows the **connected-kernels directory**
(green/yellow/red).

Unsandboxed **Developer-ID** (it binds a loopback socket and spawns `cloudflared`)
— **not** Mac App Store. AGPL-3.0-or-later, same family as the relay.

## Build & run

```sh
brew install xcodegen cloudflared    # one-time
make run                             # xcodegen generate → xcodebuild → open
```

Click the menu-bar icon for status / Start / Stop / Copy URL, or open the
dashboard for setup + the directory.

## One-time tunnel setup (you do this once, outside the app)

The app only **runs** a named tunnel — it never drives `login`/`create`/`route`.
It runs the relay-kernel WebSocket on the **Listen port** (`9443`); the tunnel
maps your hostname → that port.

```sh
cloudflared tunnel login
cloudflared tunnel create my-relay        # prints a <UUID> + ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns my-relay relay.example.com
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: my-relay
credentials-file: /Users/<you>/.cloudflared/<UUID>.json
ingress:
  - hostname: relay.example.com
    service: ws://127.0.0.1:9443
  - service: http_status:404
```

Then in the dashboard set **Named tunnel** = `my-relay`, **Public URL** =
`wss://relay.example.com`, **Listen port** = `9443`, set a **group password**, and
hit **Start** — the app runs `cloudflared tunnel run my-relay`, so don't also run
cloudflared yourself.

## Connecting a kernel

Give each of your kernels two things from the dashboard:

- **Router URL** (`wss://…`)
- **Group password**

A kernel connects to `wss://<host>/<GUID>` with subprotocol `fantastic.relay.v1`
and header `X-Fantastic-Auth: <group password>`; it then shows up in the
directory and can reach other connected kernels by GUID. See the relay
[`CONTRACT.md`](../CONTRACT.md). The ~100s idle-WS keepalive (Cloudflare Free) is
the client's job — not the relay's.

## Status

- [x] Embeds `RelayKernel`, runs the relay-kernel in-process; dashboard shows the
      green/yellow/red directory.
- [x] Keychain-backed group password; runs/stops the named cloudflared tunnel.
- [x] Sign + notarize pipeline (`scripts/build-pro.sh`).
- [ ] Verified pair against a real canvas/app relay-connector client (handoff sent).
