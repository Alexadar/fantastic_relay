# Running the relay behind your own tunnel

The router listens on loopback and is exposed by a tunnel **you** run — no
inbound ports, no certificates to manage, no cloud bill. Provisioning an
always-on managed host is a separate concern handled elsewhere; this is the
self-hosted path.

## 1. Run the router

```sh
cd router
cargo build --release

# Dev / local testing (auth + E2E gates relaxed — NEVER production):
ROUTER_REQUIRE_AUTH=false ROUTER_REQUIRE_E2E=false \
  ROUTER_LISTEN_ADDR=127.0.0.1:9443 \
  ./target/release/fantastic-router

# Production posture (strict): supply the control-plane public key and assert
# that the endpoints carry their own end-to-end encryption.
ROUTER_CONTROL_PLANE_PUBKEY=<base64-ed25519-pubkey> \
  ROUTER_E2E_ASSERTED=true \
  ROUTER_LISTEN_ADDR=127.0.0.1:9443 \
  ./target/release/fantastic-router
```

## 2. Expose it with a Cloudflare Tunnel

`cloudflared` dials OUT to Cloudflare and maps a public hostname/path to the
router on loopback. WebSockets pass through automatically.

```sh
cloudflared tunnel login
cloudflared tunnel create fantastic-relay
# Route a hostname to the tunnel (creates the DNS record):
cloudflared tunnel route dns fantastic-relay relay.example.com
```

Then a config like [`examples/cloudflared/config.yml`](../examples/cloudflared/config.yml):

```yaml
tunnel: fantastic-relay
credentials-file: /home/you/.cloudflared/<TUNNEL-ID>.json
ingress:
  - hostname: relay.example.com
    path: /fantastic/cloud/router/*
    service: ws://127.0.0.1:9443
  - service: http_status:404
```

```sh
cloudflared tunnel run fantastic-relay
```

## 3. Point apps at the router URL

In the client, enter the resulting **router URL**, e.g.
`wss://relay.example.com/fantastic/cloud/router`. That's the whole switch
between self-hosted (your tunnel) and a managed/paid endpoint — same router.

## 4. Smoke-test with `relay-probe`

With the router running in dev mode (`ROUTER_REQUIRE_AUTH=false`), pair two
probes through it:

```sh
# terminal A (listener)
PROBE_URL=ws://127.0.0.1:9443/ PROBE_PEER=A PROBE_PARTNER=B PROBE_RV=demo \
  ./target/release/relay-probe

# terminal B (sender)
PROBE_URL=ws://127.0.0.1:9443/ PROBE_PEER=B PROBE_PARTNER=A PROBE_RV=demo \
  PROBE_SEND="hello from B" ./target/release/relay-probe
```

Terminal A prints the opaque frame forwarded from B — the relay paired them and
piped bytes without inspecting them.
