import Foundation
import NIOCore
import NIOWebSocket

/// Per-session accounting shared by the two paired handlers. Either side's close
/// triggers exactly one `SessionClose` event (both byte directions). Mirrors the
/// Rust forward-loop's metering.
final class Session: @unchecked Sendable {
    let meter: Meter
    let tenantId: String
    let sessionId: String
    let started: Date
    private let lock = NSLock()
    private var aToB: UInt64 = 0
    private var bToA: UInt64 = 0
    private var seq: UInt64 = 0
    private var finished = false

    init(meter: Meter, tenantId: String, sessionId: String) {
        self.meter = meter
        self.tenantId = tenantId
        self.sessionId = sessionId
        self.started = Date()
    }

    /// Add `n` bytes in `dir`, returning the running total (both directions).
    func add(_ dir: Direction, _ n: UInt64) -> UInt64 {
        lock.withLock {
            switch dir {
            case .aToB: aToB += n
            case .bToA: bToA += n
            }
            return aToB + bToA
        }
    }

    func finish() {
        let event: UsageEvent? = lock.withLock {
            if finished { return nil }
            finished = true
            let e = UsageEvent(
                kind: .sessionClose, tenantId: tenantId, sessionId: sessionId, seq: seq,
                bytesAToB: aToB, bytesBToA: bToA,
                connSeconds: UInt64(Date().timeIntervalSince(started)))
            seq += 1
            return e
        }
        if let event { meter.record(event) }
    }
}

/// One upgraded connection. On `channelActive` it joins the rendezvous; once
/// paired it forwards opaque Text/Binary frames (opcode preserved) to the peer
/// channel, replies to Pings locally (never forwarding control frames), and
/// forwards a Close before tearing down. Mirrors the Rust `forward` pumps.
final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let claims: Claims
    unowned let server: RelayServer
    private var channel: Channel?
    private var peer: Channel?
    private var session: Session?
    private var direction: Direction = .aToB
    private var buffered: [WebSocketFrame] = []
    private var closing = false
    private var started = false

    init(claims: Claims, server: RelayServer) {
        self.claims = claims
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        // We are added to an ALREADY-ACTIVE channel (post WS upgrade), so
        // channelActive will not fire for us — start here instead.
        if context.channel.isActive {
            start(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        let eventLoop = context.eventLoop
        let deliver: (Channel, Session, Direction) -> Void = { [weak self] peer, session, dir in
            eventLoop.execute { self?.pair(peer: peer, session: session, direction: dir) }
        }
        switch server.rendezvous.join(channel: context.channel, claims: claims, deliver: deliver) {
        case .waiting, .paired:
            break
        case .rejected(let reason):
            closeWith(code: 1008, reason: reason)
        }
    }

    private func pair(peer: Channel, session: Session, direction: Direction) {
        self.peer = peer
        self.session = session
        self.direction = direction
        let pending = buffered
        buffered.removeAll()
        for frame in pending { forward(frame) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            if frame.unmaskedData.readableBytes > server.config.maxFrameBytes {
                closeWith(code: 1009, reason: "frame too large")
                return
            }
            if peer == nil {
                if buffered.count < 64 { buffered.append(frame) }
            } else {
                forward(frame)
            }
        case .ping:
            let pong = WebSocketFrame(
                fin: true, opcode: .pong, maskKey: nil, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            break
        case .connectionClose:
            if let peer {
                let f = WebSocketFrame(
                    fin: true, opcode: .connectionClose, maskKey: nil, data: frame.unmaskedData)
                peer.writeAndFlush(f, promise: nil)
            }
            context.close(promise: nil)
        default:
            break
        }
    }

    private func forward(_ frame: WebSocketFrame) {
        guard let peer, let session else { return }
        let data = frame.unmaskedData
        let total = session.add(direction, UInt64(data.readableBytes))
        if total > UInt64(server.config.maxSessionBytes) {
            closeWith(code: 1008, reason: "session byte cap")
            return
        }
        let out = WebSocketFrame(fin: frame.fin, opcode: frame.opcode, maskKey: nil, data: data)
        peer.writeAndFlush(out, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        session?.finish()
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    private func closeWith(code: UInt16, reason: String) {
        guard !closing, let channel else { return }
        closing = true
        var buf = channel.allocator.buffer(capacity: 2 + reason.utf8.count)
        buf.writeInteger(code)
        buf.writeString(reason)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: nil, data: buf)
        channel.writeAndFlush(frame).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
