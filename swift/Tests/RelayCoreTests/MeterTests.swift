import Foundation
import XCTest

@testable import RelayCore

final class MeterTests: XCTestCase {
    func testSessionIdStableAndDistinguishes() {
        let m = StdoutMeter()
        XCTAssertEqual(m.sessionId("rv-a"), m.sessionId("rv-a"))
        XCTAssertNotEqual(m.sessionId("rv-a"), m.sessionId("rv-b"))
        XCTAssertEqual(m.sessionId("rv-a").count, 16)
    }

    func testUsageEventEncodesSnakeCase() throws {
        let e = UsageEvent(
            kind: .sessionClose, tenantId: "t1", sessionId: "sid", seq: 3,
            bytesAToB: 10, bytesBToA: 20, connSeconds: 5)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as! [String: Any]
        XCTAssertEqual(obj["tenant_id"] as? String, "t1")
        XCTAssertEqual(obj["session_id"] as? String, "sid")
        XCTAssertEqual(obj["seq"] as? Int, 3)
        XCTAssertEqual(obj["bytes_a_to_b"] as? Int, 10)
        XCTAssertEqual(obj["bytes_b_to_a"] as? Int, 20)
        XCTAssertEqual(obj["conn_seconds"] as? Int, 5)
        XCTAssertEqual(obj["kind"] as? String, "session_close")
        XCTAssertNotNil(obj["event_id"] as? String)
    }

    func testHeartbeatKind() throws {
        let e = UsageEvent(
            kind: .heartbeat, tenantId: "t", sessionId: "s", seq: 0,
            bytesAToB: 0, bytesBToA: 0, connSeconds: 0)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as! [String: Any]
        XCTAssertEqual(obj["kind"] as? String, "heartbeat")
    }
}
