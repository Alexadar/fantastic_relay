import AppKit
import SwiftUI

/// The menu-bar popover: at-a-glance status + the daily verbs (start/stop, copy
/// the router URL, open the dashboard). Read-only over the shared controller.
struct MenuBarContent: View {
    @Bindable var controller: RelayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("FantasticGlyph")
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fantastic Relay").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Router URL").font(.caption2).foregroundStyle(.secondary)
                Text(controller.routerURL)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }

            HStack(spacing: 8) {
                if controller.isRunning {
                    Button("Stop") { controller.stop() }.appGlassStyle()
                } else {
                    Button("Start") { controller.start() }.appGlassStyle(prominent: true)
                }
                Button("Copy URL") { copyToPasteboard(controller.routerURL) }
                    .appGlassStyle()
                    .disabled(controller.routerURL == "—")
            }

            Divider()

            Button {
                // Promote to a regular app so the window is focusable + shows in
                // the Dock/Cmd-Tab while open; AppDelegate drops back to
                // .accessory when it closes.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            } label: {
                Label("Open Dashboard…", systemImage: "macwindow")
            }
            .buttonStyle(.plain)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 290)
    }

    private var statusText: String {
        switch controller.status {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .stopped: return .secondary
        case .running: return .green
        case .failed: return .red
        }
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
