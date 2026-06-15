import FantasticJSON
import FantasticKernel
import XCTest

@testable import RelayKernel

final class RelayKernelTests: XCTestCase {
    /// Boot the engine, register a peer in the directory, assert the router lists
    /// it green and routing to it via the kernel reaches its writer.
    func testEngineBootAndDirectory() async throws {
        let engine = RelayEngine(
            config: RelayConfig(listenPort: 0, groupToken: "t", inboxBound: 1024))
        _ = try await engine.start()

        // relay router answers reflect.
        let reflect = await engine.kernel.send(
            AgentId("relay"), .object(["type": .string("reflect")]))
        XCTAssertEqual(reflect["kind"].asString, "relay_router")

        // Register a fake peer connection + its peer_proxy agent.
        final class FakeWriter: PeerWriter, @unchecked Sendable {
            var delivered: [JSON] = []
            func deliver(_ frame: JSON) { delivered.append(frame) }
            func shutdown() {}
        }
        let w = FakeWriter()
        engine.peers.add("A", writer: w)
        _ = await engine.kernel.send(
            AgentId("core"),
            .object([
                "type": .string("create_agent"),
                "handler_module": .string("peer_proxy"),
                "id": .string("A"),
            ]))

        // Router lists A as green.
        let list = await engine.kernel.send(
            AgentId("relay"), .object(["type": .string("list_peers")]))
        let peers = list["peers"].asArray ?? []
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?["guid"].asString, "A")
        XCTAssertEqual(peers.first?["status"].asString, "green")

        // Routing a frame to A reaches its writer.
        _ = await engine.kernel.send(
            AgentId("A"), .object(["type": .string("call"), "hello": .string("world")]))
        XCTAssertEqual(w.delivered.count, 1)
        XCTAssertEqual(w.delivered.first?["hello"].asString, "world")

        engine.stop()
        engine.peers.remove("A")
    }

    func testStatusThresholds() {
        let c = RelayConfig(keepaliveSecs: 10, evictSecs: 30)
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(RelayRouterBundle.status(now, c), "green")
        XCTAssertEqual(RelayRouterBundle.status(now - 15, c), "yellow")
        XCTAssertEqual(RelayRouterBundle.status(now - 40, c), "red")
    }
}
