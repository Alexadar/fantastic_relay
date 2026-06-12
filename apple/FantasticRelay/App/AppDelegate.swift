import AppKit

/// - Single-instance: refuse to run a second copy — activate the existing one
///   and quit (no multi-app for now).
/// - Agent app: stays `.accessory` (no Dock icon, not in the running-apps list)
///   when it has no window. `MenuBarContent` promotes to `.regular` when it opens
///   the dashboard; here we drop back to `.accessory` once that window closes.
/// - Graceful shutdown on quit: stop the relay + reap the cloudflared child so we
///   never leave an orphaned tunnel running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        let others =
            NSRunningApplication
            .runningApplications(withBundleIdentifier: me.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    /// When the last regular (main-capable) window closes, become an accessory
    /// again so we vanish from the Dock / Cmd-Tab.
    @objc private func windowWillClose(_ note: Notification) {
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RelayController.shared.stop()
        return .terminateNow
    }
}
