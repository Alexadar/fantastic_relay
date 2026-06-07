#if canImport(Darwin)
    import Crypto
    import Foundation
    import XCTest

    @testable import RelayCore

    /// Full Swift path: mint a token with the embedded Issuer → run the RelayCore
    /// server in-process → two WS clients pair through it and round-trip a frame.
    /// Uses URLSessionWebSocketTask (Apple platforms; the Swift CI runs on macOS).
    final class RelayE2ETests: XCTestCase {
        func testIssueRunPairForward() async throws {
            let signing = Curve25519.Signing.PrivateKey()
            let issuer = Issuer(
                signing: signing, audience: "fantastic.relay", tokenTTLSecs: 60,
                providers: [PasswordProvider(password: "pw", tenantId: "t1")])

            let config = Config(
                listenHost: "127.0.0.1", listenPort: 0,
                controlPlanePubkeyB64: issuer.publicKeyB64,
                requireE2E: false, e2eAsserted: true)
            let server = try RelayServer(config: config)
            let handle = try server.start()
            defer { handle.shutdown() }
            guard let port = handle.localAddress?.port else { return XCTFail("no bound port") }

            let tokenA = try issuer.issue(
                provider: "password", credential: "pw", peerId: "A", partnerPeerId: "B",
                rendezvous: "rv")
            let tokenB = try issuer.issue(
                provider: "password", credential: "pw", peerId: "B", partnerPeerId: "A",
                rendezvous: "rv")

            let url = URL(string: "ws://127.0.0.1:\(port)/")!
            let session = URLSession(configuration: .ephemeral)
            let a = session.webSocketTask(with: url, protocols: ["fantastic.relay.v1", tokenA])
            let b = session.webSocketTask(with: url, protocols: ["fantastic.relay.v1", tokenB])
            a.resume()
            try await Task.sleep(nanoseconds: 200_000_000)  // A registers first
            b.resume()
            try await Task.sleep(nanoseconds: 200_000_000)

            // A → B
            try await a.send(.data(Data("ping".utf8)))
            guard case .data(let got1) = try await b.receive() else {
                return XCTFail("expected data")
            }
            XCTAssertEqual(got1, Data("ping".utf8))

            // B → A
            try await b.send(.string("pong"))
            guard case .string(let got2) = try await a.receive() else {
                return XCTFail("expected text")
            }
            XCTAssertEqual(got2, "pong")

            a.cancel(with: .goingAway, reason: nil)
            b.cancel(with: .goingAway, reason: nil)
        }
    }
#endif
