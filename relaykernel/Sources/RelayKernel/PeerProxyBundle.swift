import FantasticJSON
import FantasticKernel
import Foundation

/// One agent per connected kernel (id = the peer's GUID). A message ROUTED to this
/// agent (`kernel.send(targetGUID, …)`) is delivered out to that peer's socket via
/// the `RelayPeers` writer — this is the second leg of an A→B hop. Identity +
/// liveness live in `RelayPeers`, not the record, so `ephemeral` is fine.
public struct PeerProxyBundle: AgentBundle {
  public let name = "peer_proxy"
  public init() {}

  public func handle(agentId: AgentId, payload: JSON, kernel: Kernel) async throws -> JSON? {
    switch payload["type"].asString ?? "" {
    case "reflect":
      return .object([
        "id": .string(agentId.value),
        "kind": .string("peer_proxy"),
        "sentence": .string("A connected kernel; messages routed here go out its socket."),
      ])
    case "boot", "shutdown":
      return .object(["ok": .bool(true)])
    default:
      // Routed peer→peer traffic: deliver the frame to this peer's socket.
      guard let w = RelayPeers.shared.writer(agentId.value) else {
        return .object([
          "error": .string("peer \(agentId.value) offline"),
          "reason": .string("no_connection"),
        ])
      }
      w.deliver(payload)
      return .object(["ok": .bool(true)])
    }
  }

  public func onDelete(agentId: AgentId, kernel: Kernel) async throws {
    RelayPeers.shared.writer(agentId.value)?.shutdown()
    RelayPeers.shared.remove(agentId.value)
  }
}
