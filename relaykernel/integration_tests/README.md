# Relay integration tests — isolation, standalone ↔ container interchangeable

These prove the relay's security contract across REAL relay instances (separate
`relayd` processes, or separate containers): **N kernels spawned + external
connectors connected → no interkernel routing, no connection leakage**, even when
GUIDs collide across instances. The Swift `RelayKernelTests/IsolationTests` prove
the same per-engine isolation *inside one process*; this suite proves it across the
deployment boundary the supervisor actually uses.

The harness mirrors the canvas integration tests: one set of tests, two targets,
selected by `RELAY_TARGET` — so **standalone and container are interchangeable**.

## Run

```sh
# 0. deps (uv, like canvas)
cd relaykernel/integration_tests && uv sync

# 1. standalone (local binary) — default target
cd .. && swift build                       # produces .build/debug/relayd
uv run --project integration_tests pytest integration_tests -v

# 2. container — the shipped image, SAME tests
sh container/build.sh                       # builds relay:latest
RELAY_TARGET=container uv run --project integration_tests pytest integration_tests -v
```

`RELAY_IMAGE` overrides the image tag (default `relay:latest`). Each target run is
self-gating: local skips if `relayd` isn't built; container skips if no
podman/docker or image is present.

## What's covered

| test | asserts |
|------|---------|
| `test_single_relay_directory_and_auth` | a peer appears green in `relay.list_peers`; wrong credential refused |
| `test_directory_isolation` | each relay's directory is private (3 instances, disjoint) |
| `test_no_cross_engine_routing_on_guid_collision` | GUID `TARGET` on relay 1 **and** 2 — a send on relay 1 reaches only relay 1's TARGET; relay 2's stays silent |
| `test_credential_isolation` | relay 1 rejects relay 2's group password |
| `test_targeted_routing_no_broadcast` | within one relay, A→B reaches only B; peer C hears nothing |
| `test_binary_stream_routing` | a binary `[len\|header\|body]` codec frame routes A→B; raw body survives byte-for-byte (no base64) |
| `test_binary_no_leak_on_guid_collision` | binary routing is per-instance isolated — colliding GUID across relays does not leak |
