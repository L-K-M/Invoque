import SwiftUI

/// The launcher card's background material — Invoque's counterpart to Jetty's
/// `GlassBackground`, sharing its approach.
///
/// On **macOS 26 (Tahoe)** the glass variants render genuine **Liquid Glass** via
/// SwiftUI's public `.glassEffect`, honoring the user's Clear/Tinted and
/// Reduce-Transparency settings automatically — but only when built with the
/// macOS 26 SDK (`#if compiler(>=6.2)`): older toolchains can't see the `Glass`
/// type at all, so they compile the blur fallback unconditionally. On
/// macOS 13–15 use an `NSVisualEffectView` blur (`.popover`, the closest
/// match to the `.regularMaterial` the panel used to draw). Reduce Transparency
/// replaces either glass path with an opaque semantic surface; tinted glass
/// keeps a restrained theme wash. Solid and gradient materials use their fills.
struct PanelBackground: View {
    private static let maximumFallbackTintOpacity = 0.5

    var material: PanelMaterial
    var tint: Color
    var gradientColor: Color
    var gradientAngle: Double
    /// The user's configured opacity — Reduce Transparency is applied by the
    /// caller (`AccessibilityDisplaySettings.effectiveBackgroundOpacity`), so
    /// solid fills go fully opaque when the user asked for it.
    var opacity: Double
    var cornerRadius: CGFloat
    /// The user's Reduce Transparency setting, supplied by the caller (the
    /// `@Environment` key needs macOS 14; we target 13) — replaces both
    /// native glass and the visual-effect fallback with an opaque fill.
    var reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            switch material {
            case .liquidGlass, .glassClear, .glassTinted:
                glass(in: shape)
            case .solid:
                shape.fill(tint.opacity(opacity))
            case .gradient:
                shape.fill(
                    LinearGradient(
                        colors: [tint.opacity(opacity), gradientColor.opacity(opacity)],
                        startPoint: gradientStart,
                        endPoint: gradientEnd
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func glass(in shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            // The semantic base is opaque. Tinted glass keeps a restrained
            // wash so system label colors remain legible in either appearance.
            ZStack {
                shape.fill(.background)
                if material == .glassTinted {
                    shape.fill(tint.opacity(min(Self.maximumFallbackTintOpacity,
                                                max(0.0, opacity))))
                }
            }
        } else {
            #if compiler(>=6.2)
            // Xcode 26+ carries the macOS 26 SDK, where `Glass`/`glassEffect`
            // exist; `#available` then decides at runtime.
            if #available(macOS 26.0, *) {
                let glass: Glass = {
                    switch material {
                    case .glassClear: return .clear
                    case .glassTinted: return .regular.tint(tint.opacity(max(0.0, min(opacity, 1.0))))
                    default: return .regular
                    }
                }()
                Color.clear.glassEffect(glass, in: shape)
            } else {
                fallbackGlass(in: shape)
            }
            #else
            fallbackGlass(in: shape)
            #endif
        }
    }

    /// Fallback for macOS 13–15 and older SDKs: a blurred panel with a faint
    /// tint wash, clipped to the same rounded shape.
    @ViewBuilder
    private func fallbackGlass(in shape: RoundedRectangle) -> some View {
        ZStack {
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
            if material == .glassTinted {
                tint.opacity(min(max(0.0, opacity),
                                 Self.maximumFallbackTintOpacity))
            }
        }
        .clipShape(shape)
    }

    // 0° = top→bottom, increasing counterclockwise on screen — 90° runs left→right
    // (matches `AngleDial`; y grows downward so (sin, cos) puts 0° at the bottom).
    private var gradientStart: UnitPoint {
        let r = gradientAngle * .pi / 180
        return UnitPoint(x: 0.5 - sin(r) / 2, y: 0.5 - cos(r) / 2)
    }
    private var gradientEnd: UnitPoint {
        let r = gradientAngle * .pi / 180
        return UnitPoint(x: 0.5 + sin(r) / 2, y: 0.5 + cos(r) / 2)
    }
}
