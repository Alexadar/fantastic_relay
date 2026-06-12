import Crypto
import Foundation
import Observation
import RelayCore

/// The single state store + orchestrator. Both the menu-bar popover and the
/// dashboard window bind this one instance — no duplicated logic.
///
/// Lifecycle: load/generate the signing key → build the Issuer (control plane) →
/// run RelayServer in-process → run the pre-configured cloudflared named tunnel.
/// It IS the control plane: it holds the signing key + password and verifies with
/// the matching public key.
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
    var password: String = ""
    var pubkeyB64: String = ""
    var sessionsServed: Int = 0
    var lastUsage: String = "—"
    var logLines: [String] = []

    private var handle: RelayServerHandle?
    private var issuerServer: IssuerServer?
    private let tunnel = CloudflaredTunnel()
    private let meter = UIMeter()

    private init() {
        meter.controller = self
        password = (try? IssuerKeyStore.loadPassword()) ?? ""
    }

    var routerURL: String { settings.publicURL.isEmpty ? "—" : settings.publicURL }

    /// The token endpoint clients POST their credential to. Same host as the
    /// router URL, path `/issue` (the user's cloudflared ingress routes it to the
    /// local issuer port).
    var issueURL: String {
        guard let host = URL(string: settings.publicURL)?.host else { return "—" }
        return "https://\(host)/issue"
    }

    var isRunning: Bool { status == .running }

    func start() {
        guard status != .running else { return }
        do {
            guard !password.isEmpty else {
                throw RelayAppError.message("Set a relay password first.")
            }
            let signing = try IssuerKeyStore.loadOrCreateSigningKey()
            let issuer = Issuer(
                signing: signing, audience: RelaySettings.audience, tokenTTLSecs: 60,
                providers: [PasswordProvider(password: password, tenantId: RelaySettings.tenantId)])
            pubkeyB64 = issuer.publicKeyB64

            // Relay (verifier) — holds only the public key.
            let config = Config(
                listenHost: "127.0.0.1", listenPort: settings.listenPort,
                controlPlanePubkeyB64: issuer.publicKeyB64, audience: RelaySettings.audience)
            let server = try RelayServer(config: config, meter: meter)
            handle = try server.start()
            log("relay listening on 127.0.0.1:\(settings.listenPort)")

            // Issuer endpoint (signer) — POST /issue, password → token. The
            // signing key stays here; clients only ever send their credential.
            let endpoint = IssuerServer(issuer: issuer)
            try endpoint.start(host: "127.0.0.1", port: settings.issuePort)
            issuerServer = endpoint
            log("issuer endpoint on 127.0.0.1:\(settings.issuePort)")

            try tunnel.start(tunnelName: settings.tunnelName) { [weak self] line in
                DispatchQueue.main.async { self?.log("cloudflared: \(line)") }
            }
            log("cloudflared tunnel '\(settings.tunnelName)' started")
            status = .running
        } catch {
            stop()
            status = .failed("\(error)")
            log("FAILED: \(error)")
        }
    }

    func stop() {
        tunnel.stop()
        issuerServer?.stop()
        issuerServer = nil
        handle?.shutdown()
        handle = nil
        if status == .running { status = .stopped }
        log("stopped")
    }

    func saveSettings() {
        settings.save()
        log("settings saved")
    }

    func savePassword(_ s: String) {
        password = s
        do { try IssuerKeyStore.savePassword(s) } catch { log("password save failed: \(error)") }
    }

    /// A 60-second single-leg TEST token (sanity check only). Real devices
    /// self-mint at connect time via their own `token_command` running
    /// `fantastic-issue token` with the signing key + password — see README.
    func mintTestToken() -> String? {
        do {
            let signing = try IssuerKeyStore.loadOrCreateSigningKey()
            let issuer = Issuer(
                signing: signing, audience: RelaySettings.audience, tokenTTLSecs: 60,
                providers: [PasswordProvider(password: password, tenantId: RelaySettings.tenantId)])
            return try issuer.issue(
                provider: "password", credential: password, peerId: "A", partnerPeerId: "",
                rendezvous: UUID().uuidString)
        } catch {
            log("mint failed: \(error)")
            return nil
        }
    }

    func noteUsage(_ line: String) {
        sessionsServed += 1
        lastUsage = line
        log("usage: \(line)")
    }

    private func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}
