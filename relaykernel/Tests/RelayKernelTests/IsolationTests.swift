import Foundation
import XCTest

@testable import RelayKernel

/// The security contract: **isolation-by-instance**. Several relay-kernels in one
/// process (the case that would leak if anything were process-global) must share
/// NOTHING — no directory, no routing, no credentials. A connector on engine 1 can
/// never see, reach, or authenticate against engine 2, even when GUIDs collide.
///
/// This is the exact hack the design forbids: "3 kernels spawned + external
/// connectors connected → ensure no interkernel routing, no connection leakage."
final class IsolationTests: XCTestCase {
    private var e1: RelayEngine!
    private var e2: RelayEngine!
    private var e3: RelayEngine!
    private var p1 = 0
    private var p2 = 0
    private var p3 = 0

    override func setUp() async throws {
        // Distinct credentials AND distinct env-var names per engine: even the
        // `setenv` the password rule reads from must not clobber across instances.
        e1 = RelayEngine(
            config: RelayConfig(
                listenPort: 0, groupTokenEnv: "RELAY_TOK_1", groupToken: "secret1",
                inboxBound: 1024))
        e2 = RelayEngine(
            config: RelayConfig(
                listenPort: 0, groupTokenEnv: "RELAY_TOK_2", groupToken: "secret2",
                inboxBound: 1024))
        e3 = RelayEngine(
            config: RelayConfig(
                listenPort: 0, groupTokenEnv: "RELAY_TOK_3", groupToken: "secret3",
                inboxBound: 1024))
        p1 = try await e1.start()
        p2 = try await e2.start()
        p3 = try await e3.start()
    }

    override func tearDown() async throws {
        e1.stop()
        e2.stop()
        e3.stop()
        e1 = nil
        e2 = nil
        e3 = nil
    }

    /// Each engine owns a private connection registry. A peer on engine 1 is invisible
    /// to engines 2 and 3 — both the in-process `peers` registry and the wire-level
    /// `relay.list_peers` directory are disjoint.
    func testDirectoryIsolation() async throws {
        let c1 = RelayWSClient(port: p1, guid: "ALPHA", cred: "secret1")
        let c2 = RelayWSClient(port: p2, guid: "BETA", cred: "secret2")
        defer {
            c1.close()
            c2.close()
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        // In-process registries are disjoint.
        XCTAssertTrue(e1.peers.has("ALPHA"))
        XCTAssertFalse(e1.peers.has("BETA"))
        XCTAssertTrue(e2.peers.has("BETA"))
        XCTAssertFalse(e2.peers.has("ALPHA"))
        XCTAssertEqual(e3.peers.count(), 0)

        // Wire directory: engine 1 sees only ALPHA, engine 2 only BETA.
        try await c1.send(
            ["type": "call", "id": "1", "target": "relay", "payload": ["type": "list_peers"]])
        let r1 = try await c1.recv()
        let peers1 = ((r1["data"] as? [String: Any])?["peers"] as? [[String: Any]]) ?? []
        XCTAssertEqual(peers1.map { $0["guid"] as? String }, ["ALPHA"])

        try await c2.send(
            ["type": "call", "id": "1", "target": "relay", "payload": ["type": "list_peers"]])
        let r2 = try await c2.recv()
        let peers2 = ((r2["data"] as? [String: Any])?["peers"] as? [[String: Any]]) ?? []
        XCTAssertEqual(peers2.map { $0["guid"] as? String }, ["BETA"])
    }

    /// The core no-leak test. The SAME GUID "TARGET" is connected to engine 1 AND
    /// engine 2. A sender on engine 1 routes to "TARGET" → only engine 1's TARGET
    /// receives it. Engine 2's identically-named TARGET stays SILENT — the GUID
    /// collision across instances does not bridge the two kernels.
    func testNoCrossEngineRoutingOnGuidCollision() async throws {
        let sender1 = RelayWSClient(port: p1, guid: "SENDER", cred: "secret1")
        let target1 = RelayWSClient(port: p1, guid: "TARGET", cred: "secret1")
        let target2 = RelayWSClient(port: p2, guid: "TARGET", cred: "secret2")
        defer {
            sender1.close()
            target1.close()
            target2.close()
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // engine 1's sender routes to "TARGET".
        try await sender1.send(
            ["type": "send", "target": "TARGET", "payload": ["ping": "from-engine-1"]])

        // engine 1's TARGET receives it...
        let onE1 = try await target1.recv(3)
        XCTAssertEqual(onE1["type"] as? String, "event")
        XCTAssertEqual(onE1["source"] as? String, "SENDER")
        XCTAssertEqual((onE1["payload"] as? [String: Any])?["ping"] as? String, "from-engine-1")

        // ...and engine 2's identically-named TARGET hears NOTHING. No leak.
        let leaked = await target2.expectSilence(1.5)
        XCTAssertTrue(leaked, "engine 2's TARGET must not receive engine 1's traffic")
    }

    /// Credentials are per-instance: engine 1's password is rejected by engine 2,
    /// and vice versa. A connector holding the wrong group secret never upgrades, so
    /// it never becomes a peer — no foothold to route from.
    func testCredentialIsolationAcrossEngines() async throws {
        // engine 2's secret presented to engine 1 → rejected.
        let wrong = RelayWSClient(port: p1, guid: "INTRUDER", cred: "secret2")
        defer { wrong.close() }
        do {
            _ = try await wrong.recv(2)
            XCTFail("engine 1 must reject engine 2's credential")
        } catch {
            // handshake refused — expected.
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(e1.peers.has("INTRUDER"))
        XCTAssertEqual(e1.peers.count(), 0)

        // The correct secret for engine 1 still works (sanity: the gate isn't just
        // rejecting everything).
        let ok = RelayWSClient(port: p1, guid: "MEMBER", cred: "secret1")
        defer { ok.close() }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(e1.peers.has("MEMBER"))
    }

    /// Within ONE engine, routing is targeted: A→B reaches B and ONLY B; a third
    /// connected peer C on the same engine receives nothing. (Targeted, not broadcast
    /// — the other half of "no leakage".)
    func testTargetedRoutingNoBroadcastWithinEngine() async throws {
        let a = RelayWSClient(port: p3, guid: "A", cred: "secret3")
        let b = RelayWSClient(port: p3, guid: "B", cred: "secret3")
        let c = RelayWSClient(port: p3, guid: "C", cred: "secret3")
        defer {
            a.close()
            b.close()
            c.close()
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        try await a.send(["type": "send", "target": "B", "payload": ["msg": "for-b-only"]])

        let atB = try await b.recv(3)
        XCTAssertEqual(atB["type"] as? String, "event")
        XCTAssertEqual((atB["payload"] as? [String: Any])?["msg"] as? String, "for-b-only")

        let cSilent = await c.expectSilence(1.5)
        XCTAssertTrue(cSilent, "peer C must not receive a frame targeted at B")
    }
}
