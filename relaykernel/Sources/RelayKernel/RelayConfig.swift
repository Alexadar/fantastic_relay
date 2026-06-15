import Foundation

/// Relay-kernel configuration. One instance = one user (isolation-by-instance);
/// the standalone supervisor spawns one per user.
public struct RelayConfig: Sendable {
    public var listenHost: String
    public var listenPort: Int
    /// Auth boundary — the ingress rule resolved by NAME (canvas registry).
    /// `password` is the first concrete rule; `certificate` comes later.
    public var ingressRule: String
    /// Env var the `password` rule reads the group token from.
    public var groupTokenEnv: String
    /// Literal group token (app sets it from the Keychain; tests set it directly).
    /// Wins over `groupTokenEnv` when present.
    public var groupToken: String?
    /// A peer seen within this window is GREEN; past it (but within evict) YELLOW.
    public var keepaliveSecs: Double
    /// Past this with no frame → RED, then evicted.
    public var evictSecs: Double
    /// How often the eviction loop sweeps.
    public var sweepSecs: Double
    public var inboxBound: Int

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: Int = 9443,
        ingressRule: String = "password",
        groupTokenEnv: String = "FANTASTIC_GROUP_TOKEN",
        groupToken: String? = nil,
        keepaliveSecs: Double = 30,
        evictSecs: Double = 90,
        sweepSecs: Double = 5,
        inboxBound: Int = 8192
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.ingressRule = ingressRule
        self.groupTokenEnv = groupTokenEnv
        self.groupToken = groupToken
        self.keepaliveSecs = keepaliveSecs
        self.evictSecs = evictSecs
        self.sweepSecs = sweepSecs
        self.inboxBound = inboxBound
    }

    public static func fromEnv() -> RelayConfig {
        let env = ProcessInfo.processInfo.environment
        func intOr(_ k: String, _ d: Int) -> Int { env[k].flatMap { Int($0) } ?? d }
        var host = "127.0.0.1"
        var port = 9443
        if let addr = env["RELAY_LISTEN_ADDR"], let i = addr.lastIndex(of: ":") {
            host = String(addr[..<i])
            port = Int(addr[addr.index(after: i)...]) ?? 9443
        }
        return RelayConfig(
            listenHost: host,
            listenPort: port,
            ingressRule: env["RELAY_INGRESS_RULE"] ?? "password",
            groupTokenEnv: env["RELAY_GROUP_TOKEN_ENV"] ?? "FANTASTIC_GROUP_TOKEN",
            keepaliveSecs: Double(intOr("RELAY_KEEPALIVE_SECS", 30)),
            evictSecs: Double(intOr("RELAY_EVICT_SECS", 90)),
            inboxBound: intOr("RELAY_INBOX_BOUND", 8192)
        )
    }
}
