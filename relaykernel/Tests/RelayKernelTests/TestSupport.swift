import Foundation
import XCTest

/// A minimal relay WebSocket client for tests: connect to a relay-kernel by port +
/// GUID + credential, then `call`/`send`/`watch` and `recv` frames. Reusable across
/// suites (the isolation tests spin up several of these against several engines).
final class RelayWSClient: @unchecked Sendable {
    enum E: Error { case timeout }

    let guid: String
    private let task: URLSessionWebSocketTask
    private static let session = URLSession(configuration: .ephemeral)

    init(port: Int, guid: String, cred: String) {
        self.guid = guid
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/\(guid)")!)
        req.setValue("fantastic.relay.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        req.setValue(cred, forHTTPHeaderField: "X-Fantastic-Auth")
        self.task = Self.session.webSocketTask(with: req)
        task.resume()
    }

    func send(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Receive one frame, or throw `E.timeout` after `timeout` secs. Cancels the
    /// socket on timeout because `URLSessionWebSocketTask.receive()` ignores Task
    /// cancellation and would otherwise leave an orphaned awaiter.
    func recv(_ timeout: TimeInterval = 3) async throws -> [String: Any] {
        let text: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [task] in
                switch try await task.receive() {
                case .string(let s): return s
                case .data(let d): return String(decoding: d, as: UTF8.self)
                @unknown default: return ""
                }
            }
            group.addTask { [task] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel(with: .goingAway, reason: nil)
                throw E.timeout
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// True iff no frame arrives within `window` secs — used to assert that traffic
    /// does NOT leak across engines (the absence of an `event` is the test).
    func expectSilence(_ window: TimeInterval = 1.0) async -> Bool {
        do {
            _ = try await recv(window)
            return false  // got a frame → not silent → leak
        } catch {
            return true  // timed out with no frame → silent → isolated
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
