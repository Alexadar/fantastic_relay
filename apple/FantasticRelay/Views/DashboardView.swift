import AppKit
import SwiftUI

/// The dashboard window. Composition copied from `fantastic_app`'s welcome:
/// a vibrant animated `MeshGradient` backdrop (Liquid Glass refracts the SwiftUI
/// layer behind it — a rich moving gradient is what makes glass read as *glass*
/// instead of matte), with cards in the `welcomeCardStyle` shape: an inner
/// `.thinMaterial` panel (legible text surface) inside an outer `.clear` glass
/// border (concentric 32/22 corners, 10pt gap).
struct DashboardView: View {
    @Bindable var controller: RelayController
    @State private var passwordField = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                setupCard
                handoffCard
                activityCard
            }
            .padding(.horizontal, 22)
            // Clear the floating traffic-light buttons (hidden title bar).
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        // Transparent scroll + transparent window → the desktop shows through
        // glass, not a matte fill.
        .scrollContentBackground(.hidden)
        .background(WindowGlassBackdrop())
        .onAppear { passwordField = controller.password }
    }

    // MARK: Header (glass controls float directly over the translucent backdrop)

    private var header: some View {
        HStack(spacing: 14) {
            Image("FantasticGlyph")
                .resizable().scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fantastic Relay").font(.title3.bold())
                statusPill
            }
            Spacer()
            if controller.isRunning {
                Button("Stop", role: .destructive) { controller.stop() }
                    .buttonStyle(.glass)
            } else {
                Button("Start") { controller.start() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        // Same full-width panel chrome as the cards, with Start/Stop inside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
        .appGlassEffect(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.8), radius: 3)
            Text(statusText).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .appGlassEffect(in: Capsule(style: .continuous))
    }

    // MARK: Cards

    private var setupCard: some View {
        card("Setup", systemImage: "slider.horizontal.3") {
            field("Listen port") {
                TextField(
                    "9443", value: $controller.settings.listenPort,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder).frame(width: 110)
            }
            field("Named tunnel") {
                TextField("my-relay", text: $controller.settings.tunnelName)
                    .textFieldStyle(.roundedBorder)
            }
            field("Public URL") {
                TextField("wss://relay.example.com", text: $controller.settings.publicURL)
                    .textFieldStyle(.roundedBorder)
            }
            field("Password") {
                HStack(spacing: 8) {
                    SecureField("relay password", text: $passwordField)
                        .textFieldStyle(.roundedBorder)
                    Button("Set") { controller.savePassword(passwordField) }
                        .disabled(passwordField.isEmpty || passwordField == controller.password)
                }
            }
            Toggle("Start automatically on launch", isOn: $controller.settings.autostart)
                .controlSize(.small)
                .onChange(of: controller.settings.autostart) { _, _ in controller.saveSettings() }
            HStack(spacing: 10) {
                Button("Save settings") { controller.saveSettings() }
                Text("One-time `cloudflared login / create / route` lives in the README.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var handoffCard: some View {
        card("Pair a device", systemImage: "qrcode") {
            Text(
                "Give each device the Router URL, the Issue URL, and the password. The device "
                    + "POSTs its password to the Issue URL for a short-lived token, then presents it "
                    + "at the Router URL. The signing key never leaves this box. tenant = `\(RelaySettings.tenantId)`."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            copyRow("Router URL", controller.routerURL)
            copyRow("Issue URL", controller.issueURL)
            copyRow("Password", controller.password.isEmpty ? "—" : controller.password)

            Button {
                if let t = controller.mintTestToken() { copyToPasteboard(t) }
            } label: {
                Label("Copy test token (60s)", systemImage: "ticket")
            }
            .disabled(controller.password.isEmpty)
            .padding(.top, 2)
        }
    }

    private var activityCard: some View {
        card("Activity", systemImage: "waveform.path.ecg") {
            HStack {
                Label("\(controller.sessionsServed) sessions", systemImage: "person.2")
                Spacer()
                Text(controller.lastUsage).foregroundStyle(.secondary)
            }
            .font(.caption)
            ScrollView {
                Text(controller.logLines.suffix(40).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 150)
            .padding(10)
            .background(
                .black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: welcomeCardStyle — inner thinMaterial panel inside an outer clear-glass border

    private func card<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 18)
        // Inner MATTE panel — the readable surface for text, sitting on the clear
        // glass. Concentric corners (32 − 10 gap = 22).
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
        // The gap reveals the clear-glass refracting border over the mesh.
        .appGlassEffect(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
    }

    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label).font(.callout).frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                copyToPasteboard(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(value == "—")
        }
    }

    private var statusText: String {
        switch controller.status {
        case .stopped: return "Stopped"
        case .running: return "Running — relay + tunnel up"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .stopped: return .gray
        case .running: return .green
        case .failed: return .red
        }
    }
}
