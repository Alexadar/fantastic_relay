import Foundation

/// A connected kernel as plain values for an embedding UI (the Mac app), so the
/// app depends only on `RelayKernel` — never on the canvas `JSON`/`AgentId` types.
public struct PeerInfo: Sendable, Identifiable {
    public let id: String  // GUID
    public let status: String  // green | yellow | red
    public let lastSeen: Double
    public let since: Double
}

extension RelayEngine {
    /// The directory (green/yellow/red), read straight from the connection
    /// registry — no kernel round-trip. Same data as `relay.list_peers`.
    public func listPeers() -> [PeerInfo] {
        RelayPeers.shared.snapshot().map {
            PeerInfo(
                id: $0.guid,
                status: RelayRouterBundle.status($0.lastSeen, config),
                lastSeen: $0.lastSeen,
                since: $0.since)
        }
    }
}
