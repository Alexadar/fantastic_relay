import Crypto
import Foundation

/// Authenticates a credential and yields the tenant it maps to. Mirrors the Rust
/// `AuthProvider`. Future Apple / Google providers conform beside `PasswordProvider`.
public protocol AuthProvider {
    var name: String { get }
    /// The tenant id on success, `nil` on a bad credential.
    func authenticate(_ credential: String) -> String?
}

/// First provider: a single shared password → a single tenant. Set in the app UI
/// (Pro = self-host control plane) or passed as a CLI/env value for headless use.
public struct PasswordProvider: AuthProvider {
    private let password: String
    private let tenantId: String

    public init(password: String, tenantId: String) {
        self.password = password
        self.tenantId = tenantId
    }

    public var name: String { "password" }

    public func authenticate(_ credential: String) -> String? {
        ctEq(credential, password) ? tenantId : nil
    }
}

/// Control-plane token minter — the signing counterpart to `Ed25519Verifier`.
/// Holds the PRIVATE key; the relay daemon holds only the public key. The Pro app
/// embeds this as its self-host control plane so a device mints its own token at
/// connect time (no CLI, no human). Mirrors the Rust `Issuer`.
public struct Issuer {
    private let signing: Curve25519.Signing.PrivateKey
    private let audience: String
    private let tokenTTLSecs: UInt64
    private let providers: [AuthProvider]

    public init(
        signing: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        audience: String = "fantastic.relay",
        tokenTTLSecs: UInt64 = 60,
        providers: [AuthProvider] = []
    ) {
        self.signing = signing
        self.audience = audience
        self.tokenTTLSecs = tokenTTLSecs
        self.providers = providers
    }

    /// Std-base64 of the public key — set as the relay's `ROUTER_CONTROL_PLANE_PUBKEY`.
    public var publicKeyB64: String {
        signing.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Authenticate `credential` against the named provider; on success mint a
    /// signed token for `(peerId, partnerPeerId, rendezvous)`.
    public func issue(
        provider: String,
        credential: String,
        peerId: String,
        partnerPeerId: String,
        rendezvous: String
    ) throws -> String {
        guard let p = providers.first(where: { $0.name == provider }) else {
            throw RelayError.auth("unknown provider \(provider)")
        }
        guard let tenant = p.authenticate(credential) else {
            throw RelayError.auth("bad credential")
        }
        let now = UInt64(Date().timeIntervalSince1970)
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let claims = Claims(
            tenantId: tenant, peerId: peerId, rendezvous: rendezvous,
            partnerPeerId: partnerPeerId, aud: audience,
            iat: now, nbf: 0, exp: now + tokenTTLSecs, jti: Base64URL.encode(nonce))
        let payload = try JSONEncoder().encode(claims)
        let sig = try signing.signature(for: payload)
        return Base64URL.encode(payload) + "." + Base64URL.encode(sig)
    }
}

/// Constant-time-ish equality over equal-length inputs — good enough for a
/// personal-tool password gate.
private func ctEq(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    if x.count != y.count { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}
