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

        let pubkey = str("ROUTER_CONTROL_PLANE_PUBKEY")
        if pubkey == nil {
            throw RelayError.config("ROUTER_CONTROL_PLANE_PUBKEY is required")
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
            pairTimeoutSecs: intOr("ROUTER_PAIR_TIMEOUT_SECS", 30),
            maxFrameBytes: intOr("ROUTER_MAX_FRAME_BYTES", 16 << 20),
            maxSessionBytes: intOr("ROUTER_MAX_SESSION_BYTES", 50 << 30),
            tokenMaxLifetimeSecs: intOr("ROUTER_TOKEN_MAX_LIFETIME_SECS", 60),
            heartbeatSecs: intOr("ROUTER_HEARTBEAT_SECS", 60)
        )
    }
}
