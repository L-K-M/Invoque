import AppKit
import SwiftUI

/// The launcher's typeface — a curated choice rather than the full font
/// book. The four system designs track whatever face the platform ships
/// (SF Pro, SF Rounded, New York, SF Mono); the named families are all
/// bundled with macOS, so every option resolves on every machine.
enum PanelTypeface: String, CaseIterable, Identifiable {

    // System designs — the platform's own faces.
    case system
    case rounded
    case serif
    case monospaced

    // Named families — fixed faces, all bundled with macOS.
    case avenirNext
    case americanTypewriter
    case courierNew
    case futura
    case georgia
    case gillSans
    case helveticaNeue
    case menlo
    case optima
    case timesNewRoman

    var id: String { rawValue }

    /// The picker's label — each row draws in its own face.
    var label: String {
        switch self {
        case .system: return "System"
        case .rounded: return "System Rounded"
        case .serif: return "System Serif"
        case .monospaced: return "System Mono"
        case .avenirNext: return "Avenir Next"
        case .americanTypewriter: return "American Typewriter"
        case .courierNew: return "Courier New"
        case .futura: return "Futura"
        case .georgia: return "Georgia"
        case .gillSans: return "Gill Sans"
        case .helveticaNeue: return "Helvetica Neue"
        case .menlo: return "Menlo"
        case .optima: return "Optima"
        case .timesNewRoman: return "Times New Roman"
        }
    }

    /// The family name a named case resolves through; nil for the system
    /// designs (those go through `systemDesign` instead).
    var family: String? {
        switch self {
        case .system, .rounded, .serif, .monospaced: return nil
        default: return label
        }
    }

    /// The `Font.Design` for a system-design case — `.default` for
    /// `.system` and unused by the named families.
    private var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        default: return .default
        }
    }

    /// The AppKit-side twin of `design` — `withDesign` takes its own enum.
    private var nsDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        default: return .default
        }
    }

    // MARK: Resolution

    /// A SwiftUI font at a semantic text style, so sizing and Dynamic Type
    /// behavior stay the platform's. Named families keep the scaling via
    /// `relativeTo:`; `weight` defaults to the style's natural weight
    /// (`.headline` carries semibold, the rest are regular).
    func font(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        guard let family else { return .system(style, design: design, weight: weight) }
        let base = Font.custom(family, size: Self.pointSize(for: style),
                               relativeTo: style)
        let resolved = weight ?? (style == .headline ? .semibold : .regular)
        return resolved == .regular ? base : base.weight(resolved)
    }

    /// An AppKit font at a fixed point size — for the `NSTextField`s the
    /// panel hosts (query field, HUD). Named families resolve through their
    /// family descriptor with a system-font fallback; `weight` applies to
    /// the system designs only — an arbitrary family has no reliable medium
    /// face, so it takes regular.
    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let family {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            return NSFont(descriptor: descriptor, size: size)
                ?? .systemFont(ofSize: size, weight: weight)
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(nsDesign) else {
            return base
        }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The platform's point size for a text style, so a named family sits
    /// at the same optical size the system face would.
    private static func pointSize(for style: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style.nsTextStyle).pointSize
    }
}

private extension Font.TextStyle {
    /// `NSFont.TextStyle` predates SwiftUI's names: `.title` is `.title1`,
    /// `.caption` is `.caption1`.
    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}
