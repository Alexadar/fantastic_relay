import SwiftUI

// Liquid Glass APIs (`GlassEffectContainer`, `.glassEffect`,
// `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`) ship on
// iOS 26 / iPadOS 26 / macOS 26 ONLY. visionOS / tvOS / watchOS in the
// 26 SDK don't expose them yet. These helpers swap in plain material /
// bordered fallbacks on platforms without the glass surface so the
// codebase compiles everywhere without per-call-site #if scattering.

extension View {
    /// Picks `.glass{,Prominent}` on iOS/macOS, `.bordered{,Prominent}`
    /// elsewhere. Use in place of `.buttonStyle(.glass)` /
    /// `.buttonStyle(.glassProminent)`.
    @ViewBuilder
    func appGlassStyle(prominent: Bool = false) -> some View {
        #if os(iOS) || os(macOS)
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        #else
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        #endif
    }

    /// Picks `.glassEffect(.regular, in: shape)` on iOS/macOS,
    /// `.background(.thinMaterial, in: shape)` elsewhere.
    @ViewBuilder
    func appGlassEffect(in shape: some Shape) -> some View {
        #if os(iOS) || os(macOS)
            // Clear glass to match the home button — crisp refraction, not the
            // frosted/matte `.regular` container glass.
            self.glassEffect(.clear.interactive(), in: shape)
        #else
            self.background(.thinMaterial, in: shape)
        #endif
    }
}

extension View {
    /// Glass-styled text field — plain field over a Liquid Glass capsule,
    /// instead of the dated `.roundedBorder`. Keeps the panel's glass language.
    /// Falls back to `.roundedBorder` where glass isn't available.
    @ViewBuilder
    func appGlassField() -> some View {
        #if os(iOS) || os(macOS)
            self
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule(style: .continuous))
        #else
            self  // tvOS/watchOS: `.roundedBorder` is unavailable; default style.
        #endif
    }
}

extension View {
    /// `.textSelection(.enabled)` is iOS / iPadOS / macOS / visionOS
    /// only — NOT tvOS (no cursor / copy-paste UX) and NOT watchOS
    /// (tiny screen, no selection UX). No-op on those platforms.
    @ViewBuilder
    func appTextSelection() -> some View {
        #if os(tvOS) || os(watchOS)
            self
        #else
            self.textSelection(.enabled)
        #endif
    }
}

extension View {
    /// Picks `.glassEffectID(id, in: ns)` on iOS/macOS 26, no-op elsewhere.
    /// Children of `AppGlassContainer` use this to morph as one glass shape
    /// when they appear/disappear or move within the container's spacing.
    @ViewBuilder
    func appGlassEffectID(
        _ id: some Hashable & Sendable, in ns: Namespace.ID
    )
        -> some View
    {
        #if os(iOS) || os(macOS)
            self.glassEffectID(id, in: ns)
        #else
            self
        #endif
    }

    /// Optional variant — applies `glassEffectID` only when both an id and a
    /// namespace are supplied, else no-op. Lets `welcomeCardStyle` attach the
    /// morph id DIRECTLY on the glass view (before `.shadow`), which is
    /// required for the morph to track — a modifier between `glassEffect` and
    /// `glassEffectID` silently breaks it.
    @ViewBuilder
    func appGlassEffectID(optional id: String?, in ns: Namespace.ID?) -> some View {
        if let id, let ns {
            self.appGlassEffectID(id, in: ns)
        } else {
            self
        }
    }
}

/// `GlassEffectContainer` fallback — plain VStack on platforms without
/// the Liquid Glass surface. Drop-in replacement that takes the same
/// `spacing:` + trailing closure.
struct AppGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 18, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if os(iOS) || os(macOS)
            GlassEffectContainer(spacing: spacing, content: content)
        #else
            VStack(spacing: spacing, content: content)
        #endif
    }
}
