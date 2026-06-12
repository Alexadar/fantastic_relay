import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// The control-plane token endpoint: `POST /issue` with a JSON body
/// `{provider, credential, peer_id, partner_peer_id, rendezvous}` → a signed
/// relay token (text/plain), or 401 on a bad credential.
///
/// The signing counterpart to `RelayServer` (the verifier). Lives in the lib so
/// BOTH the embedded app AND a headless CLI can run it; the signing key stays
/// wherever this runs and clients only ever send their credential.
///
/// Provider-agnostic by design: `provider:"password"` is the POC today; Apple /
/// Google slot in later just by adding an `AuthProvider` to the `Issuer` — this
/// endpoint does not change. Mirrors the Rust `fantastic-issue serve`.
public final class IssuerServer {
    private let issuer: Issuer
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(issuer: Issuer) {
        self.issuer = issuer
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Bind + serve. Returns once listening; call `stop()` to shut down.
    public func start(host: String, port: Int) throws {
        let issuer = self.issuer
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(IssueHandler(issuer: issuer))
                }
            }
        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    /// The actually-bound address (useful when binding to port 0).
    public var localAddress: SocketAddress? { channel?.localAddress }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

private final class IssueHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let issuer: Issuer
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(issuer: Issuer) { self.issuer = issuer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
        case .body(var b):
            body.writeBuffer(&b)
        case .end:
            handle(context: context)
        }
    }

    private func handle(context: ChannelHandlerContext) {
        guard let head else { return }
        guard head.method == .POST, head.uri.hasPrefix("/issue") else {
            return respond(context, .notFound, "not found")
        }
        let bytes = body.getBytes(at: 0, length: body.readableBytes) ?? []
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
            let provider = obj["provider"] as? String,
            let credential = obj["credential"] as? String,
            let rendezvous = obj["rendezvous"] as? String
        else {
            return respond(
                context, .badRequest,
                "expected json {provider,credential,rendezvous,peer_id,partner_peer_id}")
        }
        let peer = obj["peer_id"] as? String ?? ""
        let partner = obj["partner_peer_id"] as? String ?? ""
        do {
            let token = try issuer.issue(
                provider: provider, credential: credential, peerId: peer,
                partnerPeerId: partner, rendezvous: rendezvous)
            respond(context, .ok, token)
        } catch {
            respond(context, .unauthorized, "denied")
        }
    }

    private func respond(
        _ context: ChannelHandlerContext, _ status: HTTPResponseStatus, _ text: String
    ) {
        var buf = context.channel.allocator.buffer(capacity: text.utf8.count)
        buf.writeString(text)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        headers.add(name: "Content-Length", value: String(buf.readableBytes))
        context.write(
            wrapOutboundOut(
                .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
            promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}
