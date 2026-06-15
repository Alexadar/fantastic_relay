import AppKit
import RelayKernel
import SwiftUI

/// The dashboard window. Glass styling over a transparent window; cards in the
/// `welcomeCardStyle` shape (inner `.thinMaterial` panel inside an outer clear
/// glass border). Shows the connected-kernels directory (green/yellow/red).
struct DashboardView: View {
    @Bindable var controller: RelayController
    @State private var passwordField = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                setupCard
                handoffCard
                peersCard
                activityCard
            }
            .padding(.horizontal, 22)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(WindowGlassBackdrop())
        .onAppear { passwordField = controller.credential }
    }

    // MARK: Header

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
                Button("Stop", role: .destructive) { controller.stop() }.buttonStyle(.glass)
            } else {
                Button("Start") { controller.start() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
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
                    "9443", value: $controller.settings.listenPort, format: .number.grouping(.never)
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
                    SecureField("group password", text: $passwordField)
                        .textFieldStyle(.roundedBorder)
                    Button("Set") { controller.saveCredential(passwordField) }
                        .disabled(passwordField.isEmpty || passwordField == controller.credential)
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
                "Give each of your kernels the Router URL + the group password. They connect "
                    + "to the Router URL with their own GUID and the password; this relay-kernel "
                    + "is the per-user boundary."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            copyRow("Router URL", controller.routerURL)
            copyRow("Password", controller.credential.isEmpty ? "—" : controller.credential)
        }
    }

    private var peersCard: some View {
        card("Connected kernels", systemImage: "antenna.radiowaves.left.and.right") {
            if controller.peers.isEmpty {
                Text(controller.isRunning ? "No kernels connected." : "Relay stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(controller.peers) { p in
                    HStack(spacing: 8) {
                        Circle().fill(peerColor(p.status)).frame(width: 8, height: 8)
                        Text(p.id).font(.callout.monospaced())
                        Spacer()
                        Text(p.status).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var activityCard: some View {
        card("Activity", systemImage: "waveform.path.ecg") {
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

    // MARK: helpers

    private func card<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
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
            .controlSize(.small).disabled(value == "—")
        }
    }

    private func peerColor(_ s: String) -> Color {
        s == "green" ? .green : (s == "yellow" ? .yellow : .red)
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
