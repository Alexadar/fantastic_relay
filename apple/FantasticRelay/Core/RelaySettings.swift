import Foundation

/// Non-secret settings, persisted as JSON in Application Support. The group
/// credential lives in the Keychain (see RelayController), never here. The
/// named-tunnel fields are the one-time config the user sets up per the README:
/// the relay-kernel listens on `listenPort`, and the user's cloudflared ingress
/// maps `publicURL`'s hostname → http://127.0.0.1:listenPort.
struct RelaySettings: Codable {
    var listenPort: Int = 9443  // relay-kernel WS (cloudflared ingress: host → here)
    var tunnelName: String = ""  // the pre-configured cloudflared NAMED tunnel to run
    var publicURL: String = ""  // the stable wss:// router URL the user configured
    var autostart: Bool = false

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
