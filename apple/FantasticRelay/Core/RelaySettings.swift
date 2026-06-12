import Foundation

/// Non-secret settings, persisted as JSON in Application Support. Secrets (the
/// signing key + password) live in the Keychain (see IssuerKeyStore), never here.
///
/// `tenantId` / `audience` are FIXED constants for a single-user relay — not
/// settings, not UI. The named-tunnel fields are the one-time config the user
/// sets up per the README: the relay listens on `listenPort`, and the user's
/// cloudflared ingress maps `publicURL`'s hostname → http://127.0.0.1:listenPort.
struct RelaySettings: Codable {
    var listenPort: Int = 9443  // relay WS (cloudflared ingress: host → here)
    var issuePort: Int = 9444  // issuer endpoint (cloudflared ingress: host/issue → here)
    var tunnelName: String = ""  // the pre-configured cloudflared NAMED tunnel to run
    var publicURL: String = ""  // the stable wss:// router URL the user configured
    var autostart: Bool = false

    static let tenantId = "t1"
    static let audience = "fantastic.relay"

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FantasticRelay", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("relay-settings.json")
    }

    static func load() -> RelaySettings {
        guard let data = try? Data(contentsOf: fileURL),
            let s = try? JSONDecoder().decode(RelaySettings.self, from: data)
        else { return RelaySettings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
