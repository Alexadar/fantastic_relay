import Foundation

enum RelayAppError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let m) = self { return m }
        return "error"
    }
}

/// Runs a PRE-CONFIGURED cloudflared NAMED tunnel: `cloudflared tunnel run <name>`.
///
/// The one-time `cloudflared login` → `tunnel create` → `route dns` and the
/// ingress mapping (hostname → http://127.0.0.1:<listenPort>) are the user's job,
/// documented in the README. This app NEVER drives that setup and NEVER bundles
/// cloudflared — it assumes a Homebrew install on PATH and only runs/stops it.
final class CloudflaredTunnel {
    private var process: Process?

    static func discover() -> String? {
        for p in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Spawn `cloudflared tunnel run <name>`. `onLog` streams its output (cloudflared
    /// logs to stderr). Throws if cloudflared is missing or no tunnel name is set.
    func start(tunnelName: String, onLog: @escaping (String) -> Void) throws {
        guard !tunnelName.isEmpty else {
            throw RelayAppError.message(
                "No tunnel name set — configure a named tunnel first (see README).")
        }
        guard let bin = Self.discover() else {
            throw RelayAppError.message("cloudflared not found — run `brew install cloudflared`.")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["tunnel", "run", tunnelName]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(whereSeparator: \.isNewline) {
                onLog(String(line))
            }
        }
        try proc.run()
        process = proc
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        (proc.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        proc.terminate()  // SIGTERM
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
        process = nil
    }
}
