import FantasticJSON
import FantasticKernel
import Foundation

/// The directory endpoint + control (singleton, id `relay`). Connected kernels —
/// including the orchestration app — address `relay` over their own socket to
/// `list_peers` (green/yellow/red), `evict`, and `watch` it for live changes.
/// The directory IS the agent registry filtered to `peer_proxy`; status comes
/// from `RelayPeers.last_seen`. The eviction loop lives in `RelayEngine`.
public struct RelayRouterBundle: AgentBundle {
    public let name = "relay_router"
    let config: RelayConfig
    let peers: RelayPeers  // this engine's registry (not global)
    init(config: RelayConfig, peers: RelayPeers) {
        self.config = config
        self.peers = peers
    }

    public func handle(agentId: AgentId, payload: JSON, kernel: Kernel) async throws -> JSON? {
        switch payload["type"].asString ?? "" {
        case "reflect":
            return .object([
                "id": .string(agentId.value),
                "kind": .string("relay_router"),
                "sentence": .string("Directory of connected kernels (green/yellow/red) + router."),
                "verbs": [
                    "list_peers": "Connected kernels with health status.",
                    "evict": "Force-disconnect a peer by guid.",
                ] as JSON,
            ])
        case "boot", "shutdown":
            return .object(["ok": .bool(true)])
        case "list_peers":
            return .object(["peers": .array(Self.peerList(peers, config))])
        case "evict":
            guard let guid = payload["guid"].asString else {
                return .object(["error": .string("evict requires guid")])
            }
            _ = await kernel.send(
                AgentId("core"),
                .object(["type": .string("delete_agent"), "id": .string(guid)]))
            return .object(["ok": .bool(true), "evicted": .string(guid)])
        default:
            return .object(["error": .string("unknown verb"), "reason": .string("unknown_verb")])
        }
    }

    /// green = seen within keepalive window; yellow = stale; red = past evict TTL.
    public static func status(_ lastSeen: Double, _ config: RelayConfig) -> String {
        let age = Date().timeIntervalSince1970 - lastSeen
        if age <= config.keepaliveSecs { return "green" }
        if age <= config.evictSecs { return "yellow" }
        return "red"
    }

    public static func peerList(_ peers: RelayPeers, _ config: RelayConfig) -> [JSON] {
        peers.snapshot().map { p in
            .object([
                "guid": .string(p.guid),
                "status": .string(status(p.lastSeen, config)),
                "last_seen": .double(p.lastSeen),
                "since": .double(p.since),
            ])
        }
    }
}
