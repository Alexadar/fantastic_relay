import Foundation

/// Mirrors the Rust `RouterError`. Kept small — the relay does few things.
public enum RelayError: Error, CustomStringConvertible, Sendable {
    case config(String)
    case auth(String)
    case pairing(String)

    public var description: String {
        switch self {
        case .config(let m): return "config error: \(m)"
        case .auth(let m): return "auth rejected: \(m)"
        case .pairing(let m): return "pairing failed: \(m)"
        }
    }
}
