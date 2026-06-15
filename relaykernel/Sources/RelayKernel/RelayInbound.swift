import FantasticJSON
import FantasticKernel
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Writes frames out to one connected peer's socket. Hops to the channel's event
/// loop (kernel routing calls `deliver` from arbitrary tasks).
final class PeerConnection: PeerWriter, @unchecked Sendable {
    let guid: String
    let channel: Channel
    init(guid: String, channel: Channel) {
        self.guid = guid
        self.channel = channel
    }
    func deliver(_ frame: JSON) {
        let ch = channel
        guard ch.isActive else { return }
        let text = frame.serialize()
        ch.eventLoop.execute {
            var buf = ch.allocator.buffer(capacity: text.utf8.count)
            buf.writeString(text)
            let wsf = WebSocketFrame(fin: true, opcode: .text, data: buf)
            ch.writeAndFlush(wsf, promise: nil)
        }
    }
    func shutdown() {
        let ch = channel
        guard ch.isActive else { return }
        ch.eventLoop.execute { if ch.isActive { ch.close(promise: nil) } }
    }
}

/// Per-connection WS handler: spawns the `peer_proxy` agent on connect, routes
/// inbound frames through `kernel.send`, drains the agent inbox → socket, and
/// evicts on disconnect.
final class WSPeerHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let guid: String
    let engine: RelayEngine
    private var conn: PeerConnection?

    init(guid: String, engine: RelayEngine) {
        self.guid = guid
        self.engine = engine
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let conn = PeerConnection(guid: guid, channel: context.channel)
        self.conn = conn
        engine.peers.add(guid, writer: conn)
        let engine = self.engine
        let guid = self.guid
        Task {
            // Authoritative GUID-uniqueness: create_agent rejects a duplicate.
            let res = await engine.kernel.send(
                AgentId("core"),
                .object([
                    "type": .string("create_agent"),
                    "handler_module": .string("peer_proxy"),
                    "id": .string(guid),
                    "ephemeral": .bool(true),
                ]))
            if res["error"].asString != nil {
                conn.shutdown()
                return
            }
            await engine.notifyDirectory(
                .object(["type": .string("peer_joined"), "guid": .string(guid)]))
            // Drain the agent inbox (watch events fanned here) → socket.
            for await ev in engine.kernel.ensureInbox(AgentId(guid)) {
                conn.deliver(ev)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let engine = self.engine
        let guid = self.guid
        Task {
            _ = await engine.kernel.send(
                AgentId("core"),
                .object(["type": .string("delete_agent"), "id": .string(guid)]))
            engine.removeDirectoryWatcher(guid)
            await engine.notifyDirectory(
                .object(["type": .string("peer_left"), "guid": .string(guid)]))
        }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var d = frame.unmaskedData
            let text = d.readString(length: d.readableBytes) ?? ""
            self.engine.peers.touch(guid)
            let engine = self.engine
            let guid = self.guid
            let conn = self.conn
            Task { await Self.route(text: text, guid: guid, engine: engine, conn: conn) }
        case .ping:
            var d = frame.unmaskedData
            let pong = WebSocketFrame(
                fin: true, opcode: .pong,
                data: context.channel.allocator.buffer(
                    bytes: d.readBytes(length: d.readableBytes) ?? []))
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// The relay wire protocol (mirrors the canvas web_ws envelope):
    ///   client→relay: {type:"call"|"send", id?, target, payload} | {type:"watch"|"unwatch", target}
    ///   relay→client: {type:"reply", id, data} | {type:"event", source, payload}
    /// `target:"relay"` hits the directory/router (reply correlated); any other
    /// target is a peer GUID → delivered to that peer's socket as an `event`.
    static func route(text: String, guid: String, engine: RelayEngine, conn: PeerConnection?) async
    {
        guard let conn, let frame = try? JSON.parse(text) else { return }
        let type = frame["type"].asString ?? ""
        let target = frame["target"].asString ?? "relay"
        let id = frame["id"]
        switch type {
        case "call":
            if target == "relay" {
                let reply = await engine.kernel.send(AgentId("relay"), frame["payload"])
                conn.deliver(.object(["type": .string("reply"), "id": id, "data": reply]))
            } else {
                let delivery: JSON = .object([
                    "type": .string("event"), "source": .string(guid),
                    "payload": frame["payload"], "id": id,
                ])
                let r = await engine.kernel.send(AgentId(target), delivery)
                conn.deliver(.object(["type": .string("reply"), "id": id, "data": r]))
            }
        case "send":
            let delivery: JSON = .object([
                "type": .string("event"), "source": .string(guid), "payload": frame["payload"],
            ])
            _ = await engine.kernel.send(AgentId(target), delivery)
        case "watch":
            if target == "relay" { engine.addDirectoryWatcher(guid) }
            conn.deliver(
                .object(["type": .string("reply"), "id": id, "data": .object(["ok": .bool(true)])]))
        case "unwatch":
            if target == "relay" { engine.removeDirectoryWatcher(guid) }
        default:
            conn.deliver(
                .object(["type": .string("error"), "id": id, "reason": .string("unknown_type")]))
        }
    }
}

/// The NIO WebSocket inbound surface: accept → auth-gate the upgrade → spawn a
/// peer_proxy per connection. The canvas web host is Network.framework/Apple-only,
/// so the relay owns its own NIO surface.
public final class RelayInbound: @unchecked Sendable {
    let engine: RelayEngine
    let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(engine: RelayEngine) {
        self.engine = engine
        self.group = MultiThreadedEventLoopGroup(
            numberOfThreads: max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Bind + serve. Returns the actually-bound port (useful for port 0 in tests).
    public func start(host: String, port: Int) throws -> Int {
        let engine = self.engine
        let rule = resolveRelayIngress(engine.config)

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 24,
            shouldUpgrade: { channel, head in
                let guid = Self.parseGuid(head.uri)
                let cred = head.headers.first(name: "x-fantastic-auth")
                let proto = head.headers.first(name: "sec-websocket-protocol") ?? ""
                let ok =
                    proto.contains("fantastic.relay.v1") && !guid.isEmpty
                    && rule.authorize(guid: guid, credential: cred)
                    && !engine.peers.has(guid)
                guard ok else { return channel.eventLoop.makeSucceededFuture(nil) }
                var h = HTTPHeaders()
                h.add(name: "Sec-WebSocket-Protocol", value: "fantastic.relay.v1")
                return channel.eventLoop.makeSucceededFuture(h)
            },
            upgradePipelineHandler: { channel, head in
                let guid = Self.parseGuid(head.uri)
                return channel.pipeline.addHandler(WSPeerHandler(guid: guid, engine: engine))
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            }

        let ch = try bootstrap.bind(host: host, port: port).wait()
        self.channel = ch
        return ch.localAddress?.port ?? port
    }

    public func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }

    static func parseGuid(_ uri: String) -> String {
        var s = uri
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        return s.split(separator: "/").first.map(String.init) ?? ""
    }
}
