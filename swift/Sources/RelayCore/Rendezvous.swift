import Foundation
import NIOCore

/// Forwarding direction relative to the pair. First arrival = A, second = B.
enum Direction: Sendable {
    case aToB
    case bToA
}

/// In-memory pairing registry. Lock-based (not an actor) so the NIO channel
/// callbacks can pair synchronously and hop back onto each handler's event loop
/// to wire it up. Mirrors the Rust `InMemoryRendezvous`.
final class Rendezvous: @unchecked Sendable {
    struct Key: Hashable {
        let tenant: String
        let rendezvous: String
    }

    final class Waiter {
        let channel: Channel
        let claims: Claims
        let deliver: (Channel, Session, Direction) -> Void
        var timeout: Scheduled<Void>?
        init(
            channel: Channel, claims: Claims,
            deliver: @escaping (Channel, Session, Direction) -> Void
        ) {
            self.channel = channel
            self.claims = claims
            self.deliver = deliver
        }
    }

    enum JoinResult {
        case waiting
        case paired
        case rejected(String)
    }

    private let lock = NSLock()
    private var waiting: [Key: Waiter] = [:]
    let meter: Meter
    let pairTimeout: TimeAmount

    init(meter: Meter, pairTimeout: TimeAmount) {
        self.meter = meter
        self.pairTimeout = pairTimeout
    }

    /// `deliver(peerChannel, session, direction)` MUST hop to the caller's own
    /// event loop before touching its handler. The second arrival drives the
    /// wiring for both legs.
    func join(
        channel: Channel,
        claims: Claims,
        deliver: @escaping (Channel, Session, Direction) -> Void
    ) -> JoinResult {
        let key = Key(tenant: claims.tenantId, rendezvous: claims.rendezvous)
        lock.lock()
        if let first = waiting[key] {
            if first.claims.peerId == claims.peerId {
                lock.unlock()
                return .rejected("self-pair")
            }
            if !partnerOk(first: first.claims, second: claims) {
                lock.unlock()
                return .rejected("partner-mismatch")
            }
            waiting.removeValue(forKey: key)
            lock.unlock()
            first.timeout?.cancel()
            let session = Session(
                meter: meter,
                tenantId: claims.tenantId,
                sessionId: meter.sessionId(claims.rendezvous)
            )
            // first = A, this (second) = B
            first.deliver(channel, session, .aToB)
            deliver(first.channel, session, .bToA)
            return .paired
        } else {
            let waiter = Waiter(channel: channel, claims: claims, deliver: deliver)
            waiter.timeout = channel.eventLoop.scheduleTask(in: pairTimeout) { [weak self] in
                self?.timeoutWaiter(key: key, channel: channel)
            }
            waiting[key] = waiter
            lock.unlock()
            return .waiting
        }
    }

    private func timeoutWaiter(key: Key, channel: Channel) {
        lock.lock()
        if let w = waiting[key], w.channel === channel {
            waiting.removeValue(forKey: key)
            lock.unlock()
            _ = channel.close()
        } else {
            lock.unlock()
        }
    }
}

func partnerOk(first: Claims, second: Claims) -> Bool {
    if !first.partnerPeerId.isEmpty && first.partnerPeerId != second.peerId {
        return false
    }
    if !second.partnerPeerId.isEmpty && second.partnerPeerId != first.peerId {
        return false
    }
    return true
}
