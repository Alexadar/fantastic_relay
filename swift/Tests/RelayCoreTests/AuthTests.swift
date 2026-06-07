import Crypto
import Foundation
import XCTest

@testable import RelayCore

final class AuthTests: XCTestCase {
    private let signing = Curve25519.Signing.PrivateKey()

    private func verifier() throws -> Ed25519Verifier {
        let config = Config(
            controlPlanePubkeyB64: signing.publicKey.rawRepresentation.base64EncodedString()
        )
        return try Ed25519Verifier(config: config)
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970) }

    private func token(_ claims: Claims) throws -> String {
        let payload = try JSONEncoder().encode(claims)
        let sig = try signing.signature(for: payload)
        return Base64URL.encode(payload) + "." + Base64URL.encode(Data(sig))
    }

    private func validClaims() -> Claims {
        Claims(
            tenantId: "t1", peerId: "A", rendezvous: "rv", partnerPeerId: "B",
            aud: "fantastic.relay", iat: now(), exp: now() + 30, jti: "j1")
    }

    func testValidTokenAccepted() throws {
        let v = try verifier()
        if case .failure(let e) = v.verify(try token(validClaims())) {
            XCTFail("expected accept, got \(e)")
        }
    }

    func testTamperedPayloadRejected() throws {
        let v = try verifier()
        var t = try token(validClaims())
        // Flip a character in the payload segment.
        let dot = t.firstIndex(of: ".")!
        let i = t.index(t.startIndex, offsetBy: 2)
        XCTAssertLessThan(i, dot)
        t.replaceSubrange(i...i, with: t[i] == "A" ? "B" : "A")
        XCTAssertThrowsVerdict(v.verify(t))
    }

    func testWrongAudienceRejected() throws {
        let v = try verifier()
        var c = validClaims()
        c.aud = "someone.else"
        XCTAssertThrowsVerdict(v.verify(try token(c)))
    }

    func testExpiredRejected() throws {
        let v = try verifier()
        var c = validClaims()
        c.iat = now() - 90
        c.exp = now() - 30
        XCTAssertThrowsVerdict(v.verify(try token(c)))
    }

    func testLifetimeTooLongRejected() throws {
        let v = try verifier()
        var c = validClaims()
        c.iat = now()
        c.exp = now() + 3600  // > 60s max lifetime
        XCTAssertThrowsVerdict(v.verify(try token(c)))
    }

    func testReplayedJtiRejected() throws {
        let v = try verifier()
        let t = try token(validClaims())
        if case .failure(let e) = v.verify(t) { XCTFail("first use should accept, got \(e)") }
        XCTAssertThrowsVerdict(v.verify(t))  // same jti again
    }

    func testWrongKeyRejected() throws {
        let v = try verifier()
        // Sign with a DIFFERENT key.
        let other = Curve25519.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(validClaims())
        let sig = try other.signature(for: payload)
        let t = Base64URL.encode(payload) + "." + Base64URL.encode(Data(sig))
        XCTAssertThrowsVerdict(v.verify(t))
    }

    private func XCTAssertThrowsVerdict(_ r: Result<Claims, RelayError>) {
        if case .success = r { XCTFail("expected reject, got accept") }
    }
}
