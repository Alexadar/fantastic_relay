import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// A running server: the app supervises lifetime through this handle.
public final class RelayServerHandle: @unchecked Sendable {
    public let channel: Channel
    private let group: EventLoopGroup

    init(channel: Channel, group: EventLoopGroup) {
        self.channel = channel
        self.group = group
    }

    /// The actually-bound address (useful when binding to port 0).
    public var localAddress: SocketAddress? { channel.localAddress }

    /// Graceful shutdown — close the listener and the event-loop group.
    public func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// The relay server. Mirrors the Rust `ws::serve` pipeline:
/// authenticate (subprotocol token) → pair by (tenant, rendezvous) → forward
/// opaque frames → meter.
///
/// Two entry points:
///  - `run()`   — blocking; used by the `relayd` CLI.
///  - `start()` — non-blocking; returns a handle the host app supervises.
public final class RelayServer: @unchecked Sendable {
    public let config: Config
    let verifier: Ed25519Verifier
    let rendezvous: Rendezvous
    let meter: Meter
    private let group: MultiThreadedEventLoopGroup

    // Captured Claims handed from shouldUpgrade to upgradePipelineHandler.
    private let pendingLock = NSLock()
    private var pending: [ObjectIdentifier: Claims] = [:]

    public init(config: Config, meter: Meter = StdoutMeter()) throws {
        self.config = config
        self.verifier = try Ed25519Verifier(config: config)
        self.meter = meter
        self.rendezvous = Rendezvous(
            meter: meter, pairTimeout: .seconds(Int64(config.pairTimeoutSecs)))
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() throws -> RelayServerHandle {
        let channel = try bootstrap().bind(host: config.listenHost, port: config.listenPort).wait()
        return RelayServerHandle(channel: channel, group: group)
    }

    public func run() throws {
        let handle = try start()
        try handle.channel.closeFuture.wait()
        try? group.syncShutdownGracefully()
    }

    private func bootstrap() -> ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(RelayError.config("server gone"))
                }
                return self.configureChild(channel)
            }
    }

    private func configureChild(_ channel: Channel) -> EventLoopFuture<Void> {
        // The 401 fallback for declined (unauthenticated) upgrades. It MUST be
        // removed from the pipeline when an upgrade succeeds, otherwise it sits
        // at the tail and tries to decode WebSocket bytes as HTTP (a crash).
        let notFound = NotFoundHandler()
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: min(config.maxFrameBytes, 1 << 24),
            automaticErrorHandling: true,
            shouldUpgrade: { [weak self] channel, head in
                guard let self else { return channel.eventLoop.makeSucceededFuture(nil) }
                switch self.authenticate(head) {
                case .success(let claims):
                    self.setPending(channel, claims)
                    var headers = HTTPHeaders()
                    headers.add(name: "Sec-WebSocket-Protocol", value: SUBPROTOCOL)
                    return channel.eventLoop.makeSucceededFuture(headers)
                case .failure:
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
            },
            upgradePipelineHandler: { [weak self] channel, _ in
                guard let self, let claims = self.takePending(channel) else {
                    return channel.eventLoop.makeFailedFuture(RelayError.auth("no claims"))
                }
                return channel.pipeline.removeHandler(notFound).flatMap {
                    channel.pipeline.addHandler(ConnectionHandler(claims: claims, server: self))
                }
            }
        )
        let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
            upgraders: [upgrader], completionHandler: { _ in }
        )
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
            .flatMap {
                channel.pipeline.addHandler(notFound)
            }
    }

    /// Extract + verify the token from the `Sec-WebSocket-Protocol` header.
    func authenticate(_ head: HTTPRequestHead) -> Result<Claims, RelayError> {
        guard let proto = head.headers.first(name: "Sec-WebSocket-Protocol") else {
            return .failure(.auth("no subprotocol"))
        }
        var marker = false
        var token: String?
        for piece in proto.split(separator: ",") {
            let t = piece.trimmingCharacters(in: .whitespaces)
            if t == SUBPROTOCOL {
                marker = true
            } else if !t.isEmpty {
                token = t
            }
        }
        guard marker, let token else { return .failure(.auth("missing token")) }
        return verifier.verify(token)
    }

    private func setPending(_ channel: Channel, _ claims: Claims) {
        pendingLock.withLock { pending[ObjectIdentifier(channel)] = claims }
    }

    private func takePending(_ channel: Channel) -> Claims? {
        pendingLock.withLock { pending.removeValue(forKey: ObjectIdentifier(channel)) }
    }
}

/// Responds 401 to any request that reaches it — i.e. one whose WS upgrade was
/// declined (missing/invalid token). A successful upgrade consumes the request
/// before it gets here.
final class NotFoundHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: .unauthorized, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
