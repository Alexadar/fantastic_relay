# Fantastic Relay — Swift (`swift/`)

A native Swift port so the **Pro macOS app can embed the relay in-process** — no
Rust toolchain, no FFI, no bundled binary. Same wire [`CONTRACT.md`](../CONTRACT.md)
as the [Rust router](../rust); held byte-for-byte equivalent by the
[`conformance`](../conformance) suite. Built on **SwiftNIO** + **swift-crypto**,
so it also runs on Linux.

## Two products

- **`RelayCore`** (library) — embed in an app. `RelayServer.start() ->
  RelayServerHandle` (non-blocking; bound address + `shutdown()`) for in-app
  supervision, or `RelayServer.run()` (blocking).
- **`relayd`** (executable) — the standalone daemon; reads the SAME `ROUTER_*`
  env vars as the Rust `fantastic-router` binary.

## Build & test

```sh
cd swift
swift build
swift test          # Ed25519 token-vector parity (accept/reject)
```

## Modules (mirror the Rust 1:1)

`Auth.swift` · `Issuer.swift` · `Rendezvous.swift` · `Forward.swift` ·
`Server.swift` · `Config.swift` · `Meter.swift` · `Claims.swift` ·
`RelayError.swift` · `Base64URL.swift`.

## App integration

Add a SwiftPM **path dependency** on `../fantastic_relay/swift` for the
`RelayCore` product — the same pattern the app uses for the canvas kernel
(`../fantastic_canvas/swift`). The Pro Mac app self-hosts the relay in-process
via `RelayServer.start()`, paired with a user-run tunnel for outside reach.

It also embeds **`Issuer`** as the self-host control plane — the app mints its own
tokens in-process (no CLI): build `Issuer(signing:audience:tokenTTLSecs:providers:
[PasswordProvider(password:tenantId:)])` and call `issue(provider:"password",
credential:, peerId:, partnerPeerId:, rendezvous:)`.

> The target uses Swift 5 language mode (`swiftLanguageMode(.v5)`) for now to keep
> NIO handler concurrency friction low; tightening to Swift 6 strict concurrency
> is a follow-up.
