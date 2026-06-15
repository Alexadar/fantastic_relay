import FantasticJSON
import FantasticKernel
import Foundation

#if canImport(Glibc)
    import Glibc  // setenv on Linux (Darwin provides it via Foundation on macOS)
#endif

/// Boots a relay-kernel: a `Kernel` (canvas lib) with the relay bundles, the
/// singleton `relay` router agent, the keepalive-eviction loop, and the NIO inbound
/// WS surface. Used by both `relayd` (headless) and the Mac app (embedded) — same
/// engine, different owner.
public final class RelayEngine: @unchecked Sendable {
    public let kernel: Kernel
    public let config: RelayConfig
    public private(set) var boundPort: Int = 0

    private var evictionTask: Task<Void, Never>?
    private var inbound: RelayInbound?
    private let watchersLock = NSLock()
    private var directoryWatchers: Set<String> = []

    public init(config: RelayConfig) {
        self.config = config
        let registry = BundleRegistry()
        registry.register("peer_proxy", PeerProxyBundle())
        registry.register("relay_router", RelayRouterBundle(config: config))
        self.kernel = Kernel(storage: .inMemory, bundles: registry, inboxBound: config.inboxBound)
    }

    /// Boot the kernel root + the `relay` router + the eviction loop + the inbound
    /// WS surface. Returns once listening; `boundPort` holds the actual port.
    @discardableResult
    public func start() async throws -> Int {
        // The canvas `password` ingress rule reads the expected token from the env
        // var; export the literal credential (app/tests) so the rule sees it.
        if let token = config.groupToken {
            setenv(config.groupTokenEnv, token, 1)
        }

        let root = Agent(id: AgentId("core"), handlerModule: nil, parentId: nil)
        _ = kernel.register(root)
        kernel.setRoot(root)

        _ = await kernel.send(
            AgentId("core"),
            .object([
                "type": .string("create_agent"),
                "handler_module": .string("relay_router"),
                "id": .string("relay"),
            ]))

        startEvictionLoop()

        let ib = RelayInbound(engine: self)
        boundPort = try ib.start(host: config.listenHost, port: config.listenPort)
        inbound = ib
        return boundPort
    }

    public func stop() {
        evictionTask?.cancel()
        evictionTask = nil
        inbound?.stop()
        inbound = nil
    }

    // ── Directory watch (live green/yellow/red feed for the orchestration app) ──

    func addDirectoryWatcher(_ guid: String) {
        watchersLock.lock()
        directoryWatchers.insert(guid)
        watchersLock.unlock()
    }

    func removeDirectoryWatcher(_ guid: String) {
        watchersLock.lock()
        directoryWatchers.remove(guid)
        watchersLock.unlock()
    }

    private func currentWatchers() -> [String] {
        watchersLock.lock()
        defer { watchersLock.unlock() }
        return Array(directoryWatchers)
    }

    /// Push a directory event (peer_joined / peer_left / peer_evicted) to every
    /// connected kernel that `watch`ed `relay` — their inbox drain delivers it.
    func notifyDirectory(_ event: JSON) async {
        for g in currentWatchers() {
            await kernel.emit(
                AgentId(g),
                .object([
                    "type": .string("event"), "source": .string("relay"), "payload": event,
                ]))
        }
    }

    /// Sweep `RelayPeers`; a peer past the evict TTL (red) is `delete_agent`'d —
    /// which fires `peer_proxy.onDelete`, closing the socket + clearing the entry.
    private func startEvictionLoop() {
        let kernel = self.kernel
        let evictSecs = config.evictSecs
        let sweepNanos = UInt64(config.sweepSecs * 1_000_000_000)
        evictionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sweepNanos)
                let now = Date().timeIntervalSince1970
                for p in RelayPeers.shared.snapshot() where now - p.lastSeen > evictSecs {
                    _ = await kernel.send(
                        AgentId("core"),
                        .object(["type": .string("delete_agent"), "id": .string(p.guid)]))
                    await self?.notifyDirectory(
                        .object(["type": .string("peer_evicted"), "guid": .string(p.guid)]))
                }
            }
        }
    }
}
