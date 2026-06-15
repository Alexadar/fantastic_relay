import FantasticJSON
import Foundation

/// Writes frames out to one connected peer's socket. The NIO connection handler
/// conforms to this; the bundle + eviction loop only see this seam.
public protocol PeerWriter: AnyObject, Sendable {
    func deliver(_ frame: JSON)
    func shutdown()
}

/// Registry of live peer connections, keyed by GUID. **Per-engine** (owned by a
/// `RelayEngine`, NOT a process-global) so two engines in one process — the app,
/// or the isolation tests — never share a directory or cross-route on a GUID
/// collision. Shared within an engine between the inbound surface (registers +
/// touches), the `peer_proxy` bundle (writes), and the `relay_router` (lists +
/// evicts). `last_seen` lives here — not in agent records — so per-frame touches
/// are cheap and don't churn the kernel.
public final class RelayPeers: @unchecked Sendable {
    public init() {}

    private struct Entry {
        let writer: PeerWriter
        var lastSeen: Double
        let since: Double
    }

    private let lock = NSLock()
    private var peers: [String: Entry] = [:]

    public func add(_ guid: String, writer: PeerWriter) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        peers[guid] = Entry(writer: writer, lastSeen: now, since: now)
        lock.unlock()
    }

    public func touch(_ guid: String) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        if var e = peers[guid] {
            e.lastSeen = now
            peers[guid] = e
        }
        lock.unlock()
    }

    public func remove(_ guid: String) {
        lock.lock()
        peers.removeValue(forKey: guid)
        lock.unlock()
    }

    public func has(_ guid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return peers[guid] != nil
    }

    public func writer(_ guid: String) -> PeerWriter? {
        lock.lock()
        defer { lock.unlock() }
        return peers[guid]?.writer
    }

    public func snapshot() -> [(guid: String, lastSeen: Double, since: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return peers.map { (guid: $0.key, lastSeen: $0.value.lastSeen, since: $0.value.since) }
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peers.count
    }
}
