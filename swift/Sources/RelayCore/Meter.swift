import Crypto
import Foundation

/// Why a usage event was emitted. Mirrors the Rust `UsageKind`.
public enum UsageKind: String, Codable, Sendable {
    case sessionClose = "session_close"
    case heartbeat
}

/// One usage record. `sessionId` is a SALTED hash of the rendezvous — the raw
/// rendezvous id is never logged. Mirrors the Rust `UsageEvent`.
public struct UsageEvent: Codable, Sendable {
    public var eventId: String
    public var tenantId: String
    public var sessionId: String
    public var seq: UInt64
    public var bytesAToB: UInt64
    public var bytesBToA: UInt64
    public var connSeconds: UInt64
    public var tsUnix: UInt64
    public var kind: UsageKind

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case tenantId = "tenant_id"
        case sessionId = "session_id"
        case seq
        case bytesAToB = "bytes_a_to_b"
        case bytesBToA = "bytes_b_to_a"
        case connSeconds = "conn_seconds"
        case tsUnix = "ts_unix"
        case kind
    }

    public init(
        kind: UsageKind, tenantId: String, sessionId: String, seq: UInt64,
        bytesAToB: UInt64, bytesBToA: UInt64, connSeconds: UInt64
    ) {
        self.eventId = UUID().uuidString
        self.tenantId = tenantId
        self.sessionId = sessionId
        self.seq = seq
        self.bytesAToB = bytesAToB
        self.bytesBToA = bytesBToA
        self.connSeconds = connSeconds
        self.tsUnix = UInt64(Date().timeIntervalSince1970)
        self.kind = kind
    }
}

/// Pluggable metering sink. Mirrors the Rust `Meter` trait.
public protocol Meter: Sendable {
    func record(_ event: UsageEvent)
}

/// Default impl: one JSON line per event on stdout.
public final class StdoutMeter: Meter, @unchecked Sendable {
    private let salt: Data

    public init() {
        self.salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    /// Salted, opaque session id derived from the rendezvous.
    public func sessionId(_ rendezvous: String) -> String {
        var h = SHA256()
        h.update(data: salt)
        h.update(data: Data(rendezvous.utf8))
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func record(_ event: UsageEvent) {
        if let data = try? JSONEncoder().encode(event), let s = String(data: data, encoding: .utf8)
        {
            print(s)
        }
    }
}
