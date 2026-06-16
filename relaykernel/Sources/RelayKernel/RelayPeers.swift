import FantasticJSON
import Foundation

/// Writes frames out to one connected peer's socket. The NIO connection handler
/// conforms to this; the bundle + eviction loop only see this seam.
///
/// `deliver` writes a JSON frame as a TEXT WS frame (the control plane). `deliverBinary`
/// writes a prebuilt `[4B BE len | JSON header | raw body]` codec frame as a BINARY
/// WS frame — the pure-stream path, matching the canvas `io_bridge` codec (no base64).
public protocol PeerWriter: AnyObject, Sendable {
    func deliver(_ frame: JSON)
    func deliverBinary(_ data: Data)
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
        // Peer-advertised directory typing (role/owner_guid/exposes, …). OPAQUE to
        // the relay — stored + reflected verbatim, never interpreted. `{}` until the
        // peer sends an `announce`.
        var attrs: JSON
    }

    private let lock = NSLock()
    private var peers: [String: Entry] = [:]

    public func add(_ guid: String, writer: PeerWriter) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        peers[guid] = Entry(writer: writer, lastSeen: now, since: now, attrs: .object([:]))
        lock.unlock()
    }

    /// Replace a peer's opaque `attrs` blob (an `announce`). Returns `(changed,
    /// lastSeen)` so the caller can emit `peer_updated` only on a real change and
    /// stamp it with the peer's current status; `nil` if the peer is unknown.
    public func updateAttrs(_ guid: String, _ attrs: JSON) -> (changed: Bool, lastSeen: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard var e = peers[guid] else { return nil }
        let changed = e.attrs != attrs
        e.attrs = attrs
        peers[guid] = e
        return (changed, e.lastSeen)
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

    public func snapshot() -> [(guid: String, lastSeen: Double, since: Double, attrs: JSON)] {
        lock.lock()
        defer { lock.unlock() }
        return peers.map {
            (
                guid: $0.key, lastSeen: $0.value.lastSeen, since: $0.value.since,
                attrs: $0.value.attrs
            )
        }
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peers.count
    }
}
