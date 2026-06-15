import Foundation

/// The auth boundary — abstract + pluggable, resolved by NAME. `password` is the
/// first concrete rule; `certificate` is a future rule (seam left open, not built).
/// Mirrors the canvas ingress-rule registry; once `FantasticIoBridge` is exposed as
/// a product, `PasswordRule` delegates to `IngressRules.resolve("password")` instead
/// of carrying its own compare.
public protocol RelayIngressRule: Sendable {
    /// Authorize a connecting peer from its handshake credential. Connection-level
    /// (checked once at upgrade), not per-frame.
    func authorize(guid: String, credential: String?) -> Bool
}

/// Shared group password from an env var (constant-time compare). First rule.
public struct PasswordRule: RelayIngressRule {
    private let expected: String
    public init(tokenEnv: String) {
        self.expected = ProcessInfo.processInfo.environment[tokenEnv] ?? ""
    }
    public init(expected: String) { self.expected = expected }
    public func authorize(guid: String, credential: String?) -> Bool {
        guard !expected.isEmpty, let c = credential else { return false }
        return ctEq(c, expected)
    }
}

/// Dev-only open rule.
public struct AllowAllRule: RelayIngressRule {
    public init() {}
    public func authorize(guid: String, credential: String?) -> Bool { true }
}

/// Resolve the configured ingress rule by name. Adding `certificate` later is a
/// case here + a struct — `RelayInbound` never changes. A literal `groupToken`
/// (app/tests) wins over the env var.
public func resolveRelayIngress(_ config: RelayConfig) -> RelayIngressRule {
    switch config.ingressRule {
    case "allow_all":
        return AllowAllRule()
    // case "certificate": return CertificateRule(...)   // FUTURE — seam open, not built
    default:  // "password"
        if let t = config.groupToken { return PasswordRule(expected: t) }
        return PasswordRule(tokenEnv: config.groupTokenEnv)
    }
}

func ctEq(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    if x.count != y.count { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}
