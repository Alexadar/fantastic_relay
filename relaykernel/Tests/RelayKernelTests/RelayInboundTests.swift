import FantasticIoBridge
import FantasticJSON
import Foundation
import XCTest

@testable import RelayKernel

/// End-to-end over real WebSockets against the live NIO inbound surface.
final class RelayInboundTests: XCTestCase {
    enum E: Error { case timeout }

    private var engine: RelayEngine!
    private var port: Int = 0
    private let session = URLSession(configuration: .ephemeral)

    override func setUp() async throws {
        engine = RelayEngine(
            config: RelayConfig(listenPort: 0, groupToken: "secret", inboxBound: 1024))
        port = try await engine.start()
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
    }

    // MARK: helpers

    private func connect(_ guid: String, cred: String) -> URLSessionWebSocketTask {
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/\(guid)")!)
        req.setValue("fantastic.relay.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        req.setValue(cred, forHTTPHeaderField: "X-Fantastic-Auth")
        let task = session.webSocketTask(with: req)
        task.resume()
        return task
    }

    private func send(_ task: URLSessionWebSocketTask, _ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func recv(_ task: URLSessionWebSocketTask, _ timeout: TimeInterval = 3) async throws
        -> [String: Any]
    {
        let text: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                switch try await task.receive() {
                case .string(let s): return s
                case .data(let d): return String(decoding: d, as: UTF8.self)
                @unknown default: return ""
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // URLSessionWebSocketTask.receive() ignores Task cancellation, so
                // cancel the socket itself to unblock the sibling task fast.
                task.cancel(with: .goingAway, reason: nil)
                throw E.timeout
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// Receive one raw BINARY frame (the pure-stream path) as `Data`.
    private func recvData(_ task: URLSessionWebSocketTask, _ timeout: TimeInterval = 3) async throws
        -> Data
    {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                switch try await task.receive() {
                case .data(let d): return d
                case .string(let s): return Data(s.utf8)
                @unknown default: return Data()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel(with: .goingAway, reason: nil)
                throw E.timeout
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    /// Build a codec frame (the shared canvas `FantasticIoBridge.Codec`) wrapping a
    /// relay `send` to `target`, carrying `body` at `payload.chunk`.
    private func codecFrame(target: String, body: [UInt8]) -> Data {
        let header: JSON = .object([
            "type": .string("send"),
            "target": .string(target),
            "payload": .object(["chunk": .null]),
            "_binary_path": .string("payload.chunk"),
        ])
        return Codec.encodeBinaryFrame(header: header, body: Data(body))
    }

    // MARK: tests

    func testBinaryStreamRouting() async throws {
        let a = connect("A", cred: "secret")
        let b = connect("B", cred: "secret")
        defer {
            a.cancel()
            b.cancel()
        }
        try await Task.sleep(nanoseconds: 400_000_000)  // both peer_proxy agents register

        // Raw, deliberately non-UTF8 body → proves the bytes ride the wire verbatim
        // (no base64, no text coercion).
        let body: [UInt8] = [0x00, 0xFF, 0xFE, 0xDE, 0xAD, 0xBE, 0xEF, 0x80, 0x01]
        try await a.send(.data(codecFrame(target: "B", body: body)))

        let received = try await recvData(b)
        // Decode the relay's re-framed delivery with the shared codec.
        let decoded = Codec.decodeBinaryFrame(received)
        XCTAssertNotNil(decoded)
        let (header, gotBody) = decoded ?? (.null, Data())
        XCTAssertEqual(header["type"].asString, "event")
        XCTAssertEqual(header["source"].asString, "A")
        XCTAssertEqual(header["_binary_path"].asString, "payload.chunk")
        // The body bytes survive byte-for-byte.
        XCTAssertEqual([UInt8](gotBody), body)
    }

    func testConnectDirectoryAndPeerRouting() async throws {
        let a = connect("A", cred: "secret")
        let b = connect("B", cred: "secret")
        defer {
            a.cancel()
            b.cancel()
        }
        try await Task.sleep(nanoseconds: 400_000_000)  // let both peer_proxy agents register

        // A asks the directory → both peers, green.
        try await send(
            a, ["type": "call", "id": "1", "target": "relay", "payload": ["type": "list_peers"]])
        let reply = try await recv(a)
        XCTAssertEqual(reply["type"] as? String, "reply")
        let peers = ((reply["data"] as? [String: Any])?["peers"] as? [[String: Any]]) ?? []
        XCTAssertEqual(peers.count, 2)
        let byGuid = Dictionary(
            uniqueKeysWithValues: peers.compactMap { p -> (String, String)? in
                guard let g = p["guid"] as? String, let s = p["status"] as? String else {
                    return nil
                }
                return (g, s)
            })
        XCTAssertEqual(byGuid["A"], "green")
        XCTAssertEqual(byGuid["B"], "green")

        // A → B routes through one in-kernel hop and lands on B's socket.
        try await send(a, ["type": "send", "target": "B", "payload": ["hello": "world"]])
        let event = try await recv(b)
        XCTAssertEqual(event["type"] as? String, "event")
        XCTAssertEqual(event["source"] as? String, "A")
        XCTAssertEqual((event["payload"] as? [String: Any])?["hello"] as? String, "world")
    }

    func testBadCredentialRejected() async throws {
        let bad = connect("X", cred: "wrong")
        defer { bad.cancel() }
        do {
            _ = try await recv(bad, 3)
            XCTFail("expected the upgrade to be rejected")
        } catch {
            // receive throws because the WS handshake failed (or timed out with no frames).
        }
        XCTAssertFalse(engine.peers.has("X"))
    }

    func testDirectoryWatchEvents() async throws {
        let a = connect("W", cred: "secret")
        defer { a.cancel() }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await send(a, ["type": "watch", "id": "w", "target": "relay"])
        _ = try await recv(a)  // watch ack

        let b = connect("P", cred: "secret")
        defer { b.cancel() }
        let joined = try await recv(a, 4)
        XCTAssertEqual(joined["type"] as? String, "event")
        let jp = joined["payload"] as? [String: Any]
        XCTAssertEqual(jp?["type"] as? String, "peer_joined")
        XCTAssertEqual(jp?["guid"] as? String, "P")

        b.cancel()
        let left = try await recv(a, 4)
        XCTAssertEqual((left["payload"] as? [String: Any])?["type"] as? String, "peer_left")
        XCTAssertEqual((left["payload"] as? [String: Any])?["guid"] as? String, "P")
    }

    func testKeepaliveEviction() async throws {
        engine.stop()
        engine = RelayEngine(
            config: RelayConfig(
                listenPort: 0, groupToken: "secret", evictSecs: 1.5, sweepSecs: 0.5,
                inboxBound: 1024))
        port = try await engine.start()

        let a = connect("EV", cred: "secret")
        defer { a.cancel() }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(engine.peers.has("EV"))

        // Stay silent past the evict TTL → the sweep deletes the peer_proxy.
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertFalse(engine.peers.has("EV"))
    }

    func testDuplicateGuidRejected() async throws {
        let a1 = connect("D", cred: "secret")
        defer { a1.cancel() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(engine.peers.has("D"))

        let a2 = connect("D", cred: "secret")  // same GUID → must be refused
        defer { a2.cancel() }
        do {
            _ = try await recv(a2, 3)
            XCTFail("expected duplicate-GUID connection to be rejected")
        } catch {
            // rejected at upgrade (RelayPeers.has) or closed after create_agent dup.
        }
    }
}
