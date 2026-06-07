import Foundation

/// The WebSocket subprotocol every relay client must offer (alongside the token).
public let SUBPROTOCOL = "fantastic.relay.v1"

/// Runtime configuration — env-driven, mirroring the Rust `Config`. NO secrets
/// are baked in; the relay holds only the control plane's PUBLIC key.
public struct Config: Sendable {
    public var listenHost: String
    public var listenPort: Int
    public var controlPlanePubkeyB64: String?
    public var controlPlanePubkeyNextB64: String?
    public var audience: String
    public var requireAuth: Bool
    public var requireE2E: Bool
    public var e2eAsserted: Bool
    public var pairTimeoutSecs: Int
    public var maxFrameBytes: Int
    public var maxSessionBytes: Int
    public var tokenMaxLifetimeSecs: Int
    public var heartbeatSecs: Int

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: Int = 9443,
        controlPlanePubkeyB64: String? = nil,
        controlPlanePubkeyNextB64: String? = nil,
        audience: String = "fantastic.relay",
        requireAuth: Bool = true,
        requireE2E: Bool = true,
        e2eAsserted: Bool = false,
        pairTimeoutSecs: Int = 30,
        maxFrameBytes: Int = 16 << 20,
        maxSessionBytes: Int = 50 << 30,
        tokenMaxLifetimeSecs: Int = 60,
        heartbeatSecs: Int = 60
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.controlPlanePubkeyB64 = controlPlanePubkeyB64
        self.controlPlanePubkeyNextB64 = controlPlanePubkeyNextB64
        self.audience = audience
        self.requireAuth = requireAuth
        self.requireE2E = requireE2E
        self.e2eAsserted = e2eAsserted
        self.pairTimeoutSecs = pairTimeoutSecs
        self.maxFrameBytes = maxFrameBytes
        self.maxSessionBytes = maxSessionBytes
        self.tokenMaxLifetimeSecs = tokenMaxLifetimeSecs
        self.heartbeatSecs = heartbeatSecs
    }

    public static func fromEnv() throws -> Config {
        let env = ProcessInfo.processInfo.environment
        func str(_ k: String) -> String? { env[k] }
        func intOr(_ k: String, _ d: Int) -> Int { env[k].flatMap { Int($0) } ?? d }
        func boolOr(_ k: String, _ d: Bool) -> Bool {
            guard let v = env[k]?.lowercased() else { return d }
            return ["1", "true", "yes", "on"].contains(v)
        }

        let requireAuth = boolOr("ROUTER_REQUIRE_AUTH", true)
        let pubkey = str("ROUTER_CONTROL_PLANE_PUBKEY")
        if requireAuth && pubkey == nil {
            throw RelayError.config(
                "ROUTER_CONTROL_PLANE_PUBKEY is required when ROUTER_REQUIRE_AUTH is true")
        }

        var host = "127.0.0.1"
        var port = 9443
        if let addr = str("ROUTER_LISTEN_ADDR"), let idx = addr.lastIndex(of: ":") {
            host = String(addr[..<idx])
            port = Int(addr[addr.index(after: idx)...]) ?? 9443
        }

        return Config(
            listenHost: host,
            listenPort: port,
            controlPlanePubkeyB64: pubkey,
            controlPlanePubkeyNextB64: str("ROUTER_CONTROL_PLANE_PUBKEY_NEXT"),
            audience: str("ROUTER_AUDIENCE") ?? "fantastic.relay",
            requireAuth: requireAuth,
            requireE2E: boolOr("ROUTER_REQUIRE_E2E", true),
            e2eAsserted: boolOr("ROUTER_E2E_ASSERTED", false),
            pairTimeoutSecs: intOr("ROUTER_PAIR_TIMEOUT_SECS", 30),
            maxFrameBytes: intOr("ROUTER_MAX_FRAME_BYTES", 16 << 20),
            maxSessionBytes: intOr("ROUTER_MAX_SESSION_BYTES", 50 << 30),
            tokenMaxLifetimeSecs: intOr("ROUTER_TOKEN_MAX_LIFETIME_SECS", 60),
            heartbeatSecs: intOr("ROUTER_HEARTBEAT_SECS", 60)
        )
    }
}
