import Crypto
import Foundation

/// Allowable clock skew (seconds) for `iat`/`nbf` checks. Matches the Rust impl.
private let clockSkewSecs: UInt64 = 5

private func nowUnix() -> UInt64 {
    UInt64(Date().timeIntervalSince1970)
}

/// Verifies a control-plane-signed token and extracts its `Claims`. Mirrors the
/// Rust `Ed25519Verifier`. Token wire form:
/// `<base64url-nopad(claims_json)>.<base64url-nopad(ed25519_sig)>`, the signature
/// detached over the raw claims_json bytes. A reference type so the single-use
/// `jti` cache can be shared across connections.
public final class Ed25519Verifier: @unchecked Sendable {
    private let keys: [Curve25519.Signing.PublicKey]
    private let audience: String
    private let tokenMaxLifetimeSecs: UInt64
    private let lock = NSLock()
    private var seenJti: Set<String> = []

    public init(config: Config) throws {
        var keys: [Curve25519.Signing.PublicKey] = []
        for b64 in [config.controlPlanePubkeyB64, config.controlPlanePubkeyNextB64] {
            guard let b64 else { continue }
            guard let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RelayError.config("control-plane pubkey is not valid base64")
            }
            do {
                keys.append(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
            } catch {
                throw RelayError.config("control-plane pubkey is not a valid Ed25519 key")
            }
        }
        if keys.isEmpty {
            throw RelayError.config("no control-plane pubkey configured")
        }
        self.keys = keys
        self.audience = config.audience
        self.tokenMaxLifetimeSecs = UInt64(config.tokenMaxLifetimeSecs)
    }

    public func verify(_ token: String) -> Result<Claims, RelayError> {
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let payloadB64 = String(parts[0])
        let sigB64: String? = parts.count == 2 ? String(parts[1]) : nil

        guard let payload = Base64URL.decode(payloadB64) else {
            return .failure(.auth("malformed token"))
        }
        let claims: Claims
        do {
            claims = try JSONDecoder().decode(Claims.self, from: payload)
        } catch {
            return .failure(.auth("malformed claims"))
        }

        // Signature (detached, over the raw claims_json bytes).
        guard let sigB64, let sig = Base64URL.decode(sigB64) else {
            return .failure(.auth("token missing or malformed signature"))
        }
        let ok = keys.contains { $0.isValidSignature(sig, for: payload) }
        if !ok {
            return .failure(.auth("bad signature"))
        }

        let now = nowUnix()
        if claims.exp <= now { return .failure(.auth("expired")) }
        if claims.nbf > now + clockSkewSecs { return .failure(.auth("not yet valid")) }
        if claims.iat > now + clockSkewSecs { return .failure(.auth("issued in the future")) }
        if claims.iat != 0 && claims.exp >= claims.iat
            && claims.exp - claims.iat > tokenMaxLifetimeSecs
        {
            return .failure(.auth("token lifetime too long"))
        }
        if claims.aud != audience { return .failure(.auth("wrong audience")) }
        if claims.tenantId.isEmpty || claims.peerId.isEmpty || claims.rendezvous.isEmpty {
            return .failure(.auth("incomplete claims"))
        }
        if !claims.jti.isEmpty {
            let replayed: Bool = lock.withLock {
                if seenJti.contains(claims.jti) { return true }
                seenJti.insert(claims.jti)
                return false
            }
            if replayed { return .failure(.auth("token replayed")) }
        }
        return .success(claims)
    }
}
