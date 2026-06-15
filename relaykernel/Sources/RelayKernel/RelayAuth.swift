import FantasticIoBridge
import FantasticJSON
import Foundation

/// The auth boundary — abstract + pluggable, resolved by NAME. It **delegates to
/// the canvas io_bridge ingress-rule registry** (reused as a library): `password`
/// is the first rule; `certificate` slots in once canvas registers it — no change
/// here. No local crypto / no duplicated rule.
public protocol RelayIngressRule: Sendable {
    /// Authorize a connecting peer from its handshake credential (connection-level,
    /// checked once at upgrade).
    func authorize(guid: String, credential: String?) -> Bool
}

/// Wraps a canvas `IngressRule` behind the shared `gateInbound` chokepoint.
struct CanvasIngressRule: RelayIngressRule {
    let rule: IngressRule
    func authorize(guid: String, credential: String?) -> Bool {
        let action = AuthAction(kind: "call", target: guid, verb: "connect", token: credential)
        if case .allow = gateInbound(rule: rule, action: action) { return true }
        return false
    }
}

/// Sealed fallback — used if a rule spec is unknown/malformed (e.g. `certificate`
/// before canvas adds it). Fail closed.
struct DenyRelayIngress: RelayIngressRule {
    func authorize(guid: String, credential: String?) -> Bool { false }
}

/// Resolve the configured ingress rule by name via the canvas registry. The
/// `password` rule reads its expected token from `config.groupTokenEnv` — the
/// engine sets that env from the literal `groupToken` (app/tests) when present.
public func resolveRelayIngress(_ config: RelayConfig) -> RelayIngressRule {
    let spec: JSON = .object([
        "type": .string(config.ingressRule),
        "env": .string(config.groupTokenEnv),
    ])
    do {
        return CanvasIngressRule(rule: try IngressRules.resolve(spec))
    } catch {
        return DenyRelayIngress()
    }
}
