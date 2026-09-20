import AppKit
import SwiftUI

/// The launcher's typeface — the four system designs plus any installed
/// font family. The system designs track whatever face the platform ships
/// (SF Pro, SF Rounded, New York, SF Mono); a family choice persists the
/// NSFont family name, so user-installed fonts are pickable too. An
/// uninstalled family fails to decode and falls back to the system face.
struct PanelTypeface: Hashable, Identifiable, RawRepresentable {

    /// What a choice resolves through. `.family` carries an NSFont family
    /// name — bundled or user-installed.
    enum Face: Hashable {
        case system, rounded, serif, monospaced
        case family(String)
    }

    let face: Face

    var id: String { rawValue }

    // MARK: Catalog

    /// The curated front section of the picker — the platform designs and
    /// a set of always-bundled families. The full installed list follows
    /// via `moreFamilies`.
    static let curated: [PanelTypeface] = [
        .system, .rounded, .serif, .monospaced,
        .avenirNext, .americanTypewriter, .courierNew, .futura, .georgia,
        .gillSans, .helveticaNeue, .menlo, .optima, .timesNewRoman,
    ]

    static let system = PanelTypeface(face: .system)
    static let rounded = PanelTypeface(face: .rounded)
    static let serif = PanelTypeface(face: .serif)
    static let monospaced = PanelTypeface(face: .monospaced)

    static let avenirNext = PanelTypeface(face: .family("Avenir Next"))
    static let americanTypewriter = PanelTypeface(face: .family("American Typewriter"))
    static let courierNew = PanelTypeface(face: .family("Courier New"))
    static let futura = PanelTypeface(face: .family("Futura"))
    static let georgia = PanelTypeface(face: .family("Georgia"))
    static let gillSans = PanelTypeface(face: .family("Gill Sans"))
    static let helveticaNeue = PanelTypeface(face: .family("Helvetica Neue"))
    static let menlo = PanelTypeface(face: .family("Menlo"))
    static let optima = PanelTypeface(face: .family("Optima"))
    static let timesNewRoman = PanelTypeface(face: .family("Times New Roman"))

    /// A typeface for an installed family — what the picker's full list
    /// tags each row with.
    static func custom(_ familyName: String) -> PanelTypeface {
        PanelTypeface(face: .family(familyName))
    }

    /// Every family the font manager reports, minus hidden system faces
    /// (".AppleSystemUIFont" and friends), sorted for the picker. The list
    /// doesn't change mid-session, so it's cached.
    static let installedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// Installed families that aren't already in `curated` — the picker's
    /// tail section, so a curated face never tags twice.
    static let moreFamilies: [String] = {
        let curatedNames = Set(curated.compactMap(\.family))
        return installedFamilies.filter { !curatedNames.contains($0) }
    }()

    private static let installedFamilySet = Set(installedFamilies)

    // MARK: Persistence

    /// The persisted form: the design name for system faces, or
    /// `family:<name>` for a named family — the prefix keeps a family
    /// literally called "system" from colliding with a design key.
    var rawValue: String {
        switch face {
        case .system: return "system"
        case .rounded: return "rounded"
        case .serif: return "serif"
        case .monospaced: return "monospaced"
        case .family(let name): return "family:" + name
        }
    }

    /// CamelCase keys the enum form of this type persisted for the curated
    /// families — they still decode, to their `family:` face.
    private static let legacyFamilyKeys: [String: String] = [
        "avenirNext": "Avenir Next",
        "americanTypewriter": "American Typewriter",
        "courierNew": "Courier New",
        "futura": "Futura",
        "georgia": "Georgia",
        "gillSans": "Gill Sans",
        "helveticaNeue": "Helvetica Neue",
        "menlo": "Menlo",
        "optima": "Optima",
        "timesNewRoman": "Times New Roman",
    ]

    /// Decodes the persisted form. A `family:` value must still be
    /// installed — an uninstalled font decodes to nil so callers fall back
    /// to the default rather than render a phantom selection.
    init?(rawValue: String) {
        switch rawValue {
        case "system": face = .system
        case "rounded": face = .rounded
        case "serif": face = .serif
        case "monospaced": face = .monospaced
        case let key where key.hasPrefix("family:"):
            let name = String(key.dropFirst("family:".count))
            guard Self.installedFamilySet.contains(name) else { return nil }
            face = .family(name)
        default:
            guard let name = Self.legacyFamilyKeys[rawValue] else { return nil }
            face = .family(name)
        }
    }

    // MARK: Display

    /// The picker's label — each row draws in its own face.
    var label: String {
        switch face {
        case .system: return "System"
        case .rounded: return "System Rounded"
        case .serif: return "System Serif"
        case .monospaced: return "System Mono"
        case .family(let name): return name
        }
    }

    /// The family name a `.family` face resolves through; nil for the
    /// system designs (those go through `design` instead).
    var family: String? {
        guard case .family(let name) = face else { return nil }
        return name
    }

    /// The `Font.Design` for a system-design face — `.default` for
    /// `.system` and unused by named families.
    private var design: Font.Design {
        switch face {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        default: return .default
        }
    }

    /// The AppKit-side twin of `design` — `withDesign` takes its own enum.
    private var nsDesign: NSFontDescriptor.SystemDesign {
        switch face {
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
