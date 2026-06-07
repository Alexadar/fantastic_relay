import Foundation

/// What the relay learns from a valid token. Mirrors the Rust `Claims`; the
/// `#[serde(default)]` fields are optional in JSON, so the decoder fills
/// defaults for any that are absent.
public struct Claims: Codable, Sendable {
    public var tenantId: String
    public var peerId: String
    public var rendezvous: String
    public var partnerPeerId: String
    public var aud: String
    public var iat: UInt64
    public var nbf: UInt64
    public var exp: UInt64
    public var jti: String

    enum CodingKeys: String, CodingKey {
        case tenantId = "tenant_id"
        case peerId = "peer_id"
        case rendezvous
        case partnerPeerId = "partner_peer_id"
        case aud, iat, nbf, exp, jti
    }

    public init(
        tenantId: String, peerId: String, rendezvous: String,
        partnerPeerId: String = "", aud: String = "",
        iat: UInt64 = 0, nbf: UInt64 = 0, exp: UInt64, jti: String = ""
    ) {
        self.tenantId = tenantId
        self.peerId = peerId
        self.rendezvous = rendezvous
        self.partnerPeerId = partnerPeerId
        self.aud = aud
        self.iat = iat
        self.nbf = nbf
        self.exp = exp
        self.jti = jti
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tenantId = try c.decode(String.self, forKey: .tenantId)
        peerId = try c.decode(String.self, forKey: .peerId)
        rendezvous = try c.decode(String.self, forKey: .rendezvous)
        partnerPeerId = try c.decodeIfPresent(String.self, forKey: .partnerPeerId) ?? ""
        aud = try c.decodeIfPresent(String.self, forKey: .aud) ?? ""
        iat = try c.decodeIfPresent(UInt64.self, forKey: .iat) ?? 0
        nbf = try c.decodeIfPresent(UInt64.self, forKey: .nbf) ?? 0
        exp = try c.decode(UInt64.self, forKey: .exp)
        jti = try c.decodeIfPresent(String.self, forKey: .jti) ?? ""
    }
}
