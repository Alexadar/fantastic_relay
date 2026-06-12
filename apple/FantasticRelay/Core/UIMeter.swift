import Crypto
import Foundation
import RelayCore

/// A `RelayCore.Meter` that folds usage events into the (MainActor) controller so
/// the UI can show traffic. `record(_:)` fires on a NIO event-loop thread, so it
/// hops to the main actor before touching the controller.
///
/// Note: the relay emits `session_close` (and, on the Rust twin, `heartbeat`);
/// there is no `session_open` event by design (it would diverge the wire shape
/// from the Rust twin). So the UI shows sessions-served + the last event, not a
/// live connection table — honest for an alpha personal tool.
final class UIMeter: Meter, @unchecked Sendable {
    private let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    weak var controller: RelayController?

    func record(_ event: UsageEvent) {
        let line =
            "\(event.kind.rawValue) · \(event.sessionId) · ↑\(event.bytesAToB) ↓\(event.bytesBToA) B · \(event.connSeconds)s"
        DispatchQueue.main.async { [weak controller] in
            controller?.noteUsage(line)
        }
    }

    /// Salted, opaque session id (own per-instance salt) — the raw rendezvous id
    /// never reaches the UI or logs.
    func sessionId(_ rendezvous: String) -> String {
        var h = SHA256()
        h.update(data: salt)
        h.update(data: Data(rendezvous.utf8))
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
