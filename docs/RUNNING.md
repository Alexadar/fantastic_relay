# Running the relay-kernel behind your own tunnel

The relay-kernel listens on loopback and is exposed by a NAMED cloudflared tunnel
**you** run — no inbound ports, no certificates to manage. One relay-kernel = one
user.

## 1. Run the relay-kernel

```sh
cd relaykernel
FANTASTIC_GROUP_TOKEN=<your-group-password> \
  RELAY_LISTEN_ADDR=127.0.0.1:9443 \
  swift run relayd
```

(Or use the operator macOS app in `apple/`, which embeds the same engine and runs
the tunnel for you.)

## 2. Expose it with a cloudflared named tunnel (one-time)

```sh
cloudflared tunnel login
cloudflared tunnel create fantastic-relay
cloudflared tunnel route dns fantastic-relay relay.example.com
```

Then `~/.cloudflared/config.yml` (see [`examples/cloudflared/config.yml`](../examples/cloudflared/config.yml)):

```yaml
tunnel: fantastic-relay
credentials-file: /Users/you/.cloudflared/<TUNNEL-ID>.json
ingress:
  - hostname: relay.example.com
    service: ws://127.0.0.1:9443
  - service: http_status:404
```

Run it: `cloudflared tunnel run fantastic-relay` (the app does this for you).

## 3. Connect a kernel

```
wss://relay.example.com/<GUID>
  Sec-WebSocket-Protocol: fantastic.relay.v1
  X-Fantastic-Auth: <your-group-password>
```

Then speak the wire protocol in [`CONTRACT.md`](../CONTRACT.md): `call`/`send` to a
peer GUID, or `call relay {type:list_peers}` for the green/yellow/red directory.
