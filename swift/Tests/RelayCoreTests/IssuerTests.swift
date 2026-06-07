import Crypto
import Foundation
import XCTest

@testable import RelayCore

final class IssuerTests: XCTestCase {
    private func issuer() -> Issuer {
        Issuer(
            audience: "fantastic.relay", tokenTTLSecs: 60,
            providers: [PasswordProvider(password: "pw", tenantId: "t1")])
    }

    func testPasswordProvider() {
        let p = PasswordProvider(password: "pw", tenantId: "t1")
        XCTAssertEqual(p.name, "password")
        XCTAssertEqual(p.authenticate("pw"), "t1")
        XCTAssertNil(p.authenticate("nope"))
    }

    func testIssueOk() throws {
        XCTAssertNoThrow(
            try issuer().issue(
                provider: "password", credential: "pw", peerId: "A", partnerPeerId: "B",
                rendezvous: "rv"))
    }

    func testIssueWrongPassword() {
        XCTAssertThrowsError(
            try issuer().issue(
                provider: "password", credential: "x", peerId: "A", partnerPeerId: "B",
                rendezvous: "rv"))
    }

    func testIssueUnknownProvider() {
        XCTAssertThrowsError(
            try issuer().issue(
                provider: "google", credential: "pw", peerId: "A", partnerPeerId: "B",
                rendezvous: "rv"))
    }

    func testIssueThenVerifyRoundTrip() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let iss = Issuer(
            signing: signing, audience: "fantastic.relay", tokenTTLSecs: 60,
            providers: [PasswordProvider(password: "pw", tenantId: "t1")])
        let token = try iss.issue(
            provider: "password", credential: "pw", peerId: "A", partnerPeerId: "B",
            rendezvous: "rv")

        let verifier = try Ed25519Verifier(config: Config(controlPlanePubkeyB64: iss.publicKeyB64))
        guard case .success(let claims) = verifier.verify(token) else {
            return XCTFail("verifier rejected an issued token")
        }
        XCTAssertEqual(claims.tenantId, "t1")
        XCTAssertEqual(claims.peerId, "A")
        XCTAssertEqual(claims.partnerPeerId, "B")
        XCTAssertEqual(claims.rendezvous, "rv")
    }
}
