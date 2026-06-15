import Foundation
import Observation
import RelayKernel

/// The single state store + orchestrator. Both the menu-bar popover and the
/// dashboard window bind this one instance.
///
/// Lifecycle: build a `RelayConfig` (listen port + group credential) → run the
/// `RelayEngine` (the canvas-kernel-based relay) in-process → run the
/// pre-configured cloudflared named tunnel → poll the directory (green/yellow/red).
@MainActor
@Observable
final class RelayController {
    static let shared = RelayController()

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    var status: Status = .stopped
    var settings = RelaySettings.load()
    var credential: String = ""  // the shared group password
    var peers: [PeerInfo] = []  // connected kernels, green/yellow/red
    var logLines: [String] = []

    private var engine: RelayEngine?
    private let tunnel = CloudflaredTunnel()
    private var pollTask: Task<Void, Never>?

    static let credentialAccount = "relay-group-credential"

    private init() {
        credential = (try? KeychainStore.getString(account: Self.credentialAccount)) ?? ""
    }

    var routerURL: String { settings.publicURL.isEmpty ? "—" : settings.publicURL }
    var isRunning: Bool { status == .running }

    func start() {
        guard status != .running else { return }
        guard !credential.isEmpty else {
            status = .failed("Set a group password first.")
            return
        }
        let config = RelayConfig(
            listenHost: "127.0.0.1",
            listenPort: settings.listenPort,
            groupToken: credential)
        let engine = RelayEngine(config: config)
        self.engine = engine
        Task {
            do {
                let port = try await engine.start()
                log("relay-kernel listening on 127.0.0.1:\(port)")
                try tunnel.start(tunnelName: settings.tunnelName) { [weak self] line in
                    Task { @MainActor in self?.log("cloudflared: \(line)") }
                }
                log("cloudflared tunnel '\(settings.tunnelName)' started")
                status = .running
                startPolling()
            } catch {
                stop()
                status = .failed("\(error)")
                log("FAILED: \(error)")
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        tunnel.stop()
        engine?.stop()
        engine = nil
        peers = []
        if status == .running { status = .stopped }
        log("stopped")
    }

    func saveSettings() {
        settings.save()
        log("settings saved")
    }

    func saveCredential(_ s: String) {
        credential = s
        do { try KeychainStore.setString(s, account: Self.credentialAccount) } catch {
            log("credential save failed: \(error)")
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.refreshPeers() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refreshPeers() {
        peers = engine?.listPeers() ?? []
    }

    private func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}
