import Foundation
import XCTest

@testable import RelayCore

final class ClaimsTests: XCTestCase {
    func testDecodesFull() throws {
        let json = #"""
            {"tenant_id":"t","peer_id":"p","rendezvous":"r","partner_peer_id":"q",
             "aud":"a","iat":1,"nbf":2,"exp":3,"jti":"j"}
            """#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Claims.self, from: json)
        XCTAssertEqual(c.tenantId, "t")
        XCTAssertEqual(c.peerId, "p")
        XCTAssertEqual(c.rendezvous, "r")
        XCTAssertEqual(c.partnerPeerId, "q")
        XCTAssertEqual(c.aud, "a")
        XCTAssertEqual(c.iat, 1)
        XCTAssertEqual(c.nbf, 2)
        XCTAssertEqual(c.exp, 3)
        XCTAssertEqual(c.jti, "j")
    }

    func testDefaultsForMissingOptionals() throws {
        let json = #"{"tenant_id":"t","peer_id":"p","rendezvous":"r","exp":9}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Claims.self, from: json)
        XCTAssertEqual(c.partnerPeerId, "")
        XCTAssertEqual(c.aud, "")
        XCTAssertEqual(c.iat, 0)
        XCTAssertEqual(c.nbf, 0)
        XCTAssertEqual(c.jti, "")
        XCTAssertEqual(c.exp, 9)
    }

    func testRequiresExp() {
        let json = #"{"tenant_id":"t","peer_id":"p","rendezvous":"r"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Claims.self, from: json))
    }

    func testEncodesSnakeCase() throws {
        let c = Claims(tenantId: "t", peerId: "p", rendezvous: "r", exp: 5)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        XCTAssertNotNil(obj["tenant_id"])
        XCTAssertNotNil(obj["peer_id"])
        XCTAssertNotNil(obj["partner_peer_id"])
        XCTAssertNil(obj["tenantId"])
    }
}
