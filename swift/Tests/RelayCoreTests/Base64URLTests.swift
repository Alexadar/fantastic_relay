import Foundation
import XCTest

@testable import RelayCore

final class Base64URLTests: XCTestCase {
    func testRoundTrip() {
        let data = Data([0, 1, 2, 250, 255, 128, 64, 63, 62])
        let enc = Base64URL.encode(data)
        XCTAssertFalse(enc.contains("+"))
        XCTAssertFalse(enc.contains("/"))
        XCTAssertFalse(enc.contains("="))
        XCTAssertEqual(Base64URL.decode(enc), data)
    }

    func testRoundTripAllLengths() {
        for n in 0..<24 {
            let d = Data((0..<n).map { UInt8($0 & 0xff) })
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(d)), d, "length \(n)")
        }
    }

    func testRejectsGarbage() {
        XCTAssertNil(Base64URL.decode("!!! not base64 !!!"))
    }
}
