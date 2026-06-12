import AppKit
import SwiftUI

/// Makes the host window FULLY transparent — no frosted vibrancy material at all,
/// so the desktop shows through sharply (`.clear`) and only the glass cards float
/// on top. Frosted `NSVisualEffectView` materials always read as matte; this
/// removes them and just clears the window. Attach with
/// `.background(WindowGlassBackdrop())`; it draws nothing itself.
struct WindowGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { clear(from: probe) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { clear(from: nsView) }
    }

    private func clear(from probe: NSView) {
        guard let window = probe.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Strip any frosted backdrop a previous build may have inserted.
        window.contentView?.subviews
            .filter { $0 is NSVisualEffectView }
            .forEach { $0.removeFromSuperview() }
    }
}
