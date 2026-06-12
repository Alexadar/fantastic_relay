import AppKit
import SwiftUI

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var controller = RelayController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            // MenuBarExtra ignores the menu-bar context and uses the image's
            // intrinsic size (huge), so redraw the glyph into a menu-bar-sized
            // (~18pt) NSImage. Kept full-color (not a template) on purpose.
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Fantastic Relay", id: "dashboard") {
            DashboardView(controller: controller)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
        // Seamless: no title-bar surface — the mesh runs edge-to-edge and the
        // traffic-light buttons float over the content.
        .windowStyle(.hiddenTitleBar)
        // Don't open the dashboard at launch — it appears only when summoned
        // from the menu bar (agent app).
        .defaultLaunchBehavior(.suppressed)
    }

    /// The glyph redrawn at menu-bar size (~18pt). NSImage's reported `size` is
    /// what the status item respects.
    private static var menuBarIcon: NSImage {
        let side: CGFloat = 18
        let target = NSImage(size: NSSize(width: side, height: side))
        guard let base = NSImage(named: "FantasticGlyph") else { return target }
        target.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        target.unlockFocus()
        return target
    }
}
