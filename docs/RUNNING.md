# Running the relay behind your own tunnel

The router listens on loopback and is exposed by a tunnel **you** run — no
inbound ports, no certificates to manage, no cloud bill. Provisioning an
always-on managed host is a separate concern handled elsewhere; this is the
self-hosted path.

## 1. Run the router

```sh
cd rust
cargo build --release

# One-time: generate a control-plane keypair (auth is ALWAYS on).
eval "$(./target/release/fantastic-issue keygen | grep -v '^#')"
# Run the router with the verifier public key.
ROUTER_CONTROL_PLANE_PUBKEY="$ROUTER_CONTROL_PLANE_PUBKEY" \
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

Mint a token per peer with `fantastic-issue` (uses the `RELAY_SIGNING_KEY` from
the keygen above; pick any `RELAY_PASSWORD`), then run two probes:

```sh
export RELAY_PASSWORD=hunter2
A=$(./target/release/fantastic-issue token --password hunter2 --peer A --partner B --rendezvous demo)
B=$(./target/release/fantastic-issue token --password hunter2 --peer B --partner A --rendezvous demo)

# terminal A (listener)
PROBE_URL=ws://127.0.0.1:9443/ PROBE_TOKEN="$A" ./target/release/relay-probe
# terminal B (sender)
PROBE_URL=ws://127.0.0.1:9443/ PROBE_TOKEN="$B" PROBE_SEND="hi" ./target/release/relay-probe
```

Terminal A prints the opaque frame forwarded from B — the relay paired them and
piped bytes without inspecting them.
