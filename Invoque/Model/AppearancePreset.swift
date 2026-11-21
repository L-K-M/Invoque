import AppKit
import LiveryKit

/// A named, shareable snapshot of every appearance setting — exported/imported
/// as a small `.json` file and applied with one click, plus a set of built-in
/// themes. Decoupled from `Preferences` so it round-trips as plain data and can
/// be unit-tested. Mirrors the family's preset model (Zap, Jetty) and can
/// **import their theme files too** — see `decode(from:)`.
///
/// The persisted field names deliberately match Jetty's where the settings
/// coincide (`material`, `tintHex`, `gradientHex`, `decoration*`, `crt*`), so a
/// theme exported here also imports into Jetty.
struct AppearancePreset: Codable, Equatable, Identifiable {
    var name: String
    var material: PanelMaterial
    var tintHex: String
    var gradientHex: String
    var gradientAngle: Double
    var backgroundOpacity: Double
    var highlightHex: String
    var highlightOpacity: Double
    var labelHex: String
    /// The panel typeface's raw value — `PanelTypeface(rawValue:)`. Invoque's
    /// own field: Zap/Jetty themes have no typeface, so their lenses and
    /// decode take the default. The memberwise default keeps the built-in
    /// and import initializers source-compatible.
    var typeface: String = Preferences.Default.panelTypeface.rawValue
    var cornerRadius: Double
    var highlightCornerRadius: Double
    var adaptiveAccent: Bool
    // Retro flourishes (Zap parity)
    var decorationStyle: String
    var decorationPosition: String
    var decorationOpacity: Double
    var decorationSize: Double
    var crtEnabled: Bool
    var crtIntensity: Double

    /// Presets are identified (and de-duplicated in menus) by name.
    var id: String { name }
}

// MARK: - Snapshot / apply

extension AppearancePreset {

    /// Captures the current appearance settings under `name`.
    init(name: String, from preferences: Preferences) {
        self.name = name
        material = preferences.panelMaterial
        tintHex = preferences.tintHex
        gradientHex = preferences.gradientHex
        gradientAngle = preferences.gradientAngle
        backgroundOpacity = preferences.backgroundOpacity
        highlightHex = preferences.highlightHex
        highlightOpacity = preferences.highlightOpacity
        labelHex = preferences.labelHex
        typeface = preferences.panelTypeface.rawValue
        cornerRadius = preferences.panelCornerRadius
        highlightCornerRadius = preferences.highlightCornerRadius
        adaptiveAccent = preferences.adaptiveAccent
        decorationStyle = preferences.decorationStyle.rawValue
        decorationPosition = preferences.decorationPosition.rawValue
        decorationOpacity = preferences.decorationOpacity
        decorationSize = preferences.decorationSize
        crtEnabled = preferences.crtEnabled
        crtIntensity = preferences.crtIntensity
    }

    /// Applies the preset, validating and clamping every value the same way
    /// `Preferences` does on load — so an imported (possibly hand-edited or
    /// stale) file can never push a setting out of range or set an invalid color.
    func apply(to preferences: Preferences) {
        let limits = Preferences.Limit.self
        preferences.panelMaterial = material
        preferences.tintHex = Self.validColor(tintHex, default: Preferences.Default.tintHex)
        preferences.gradientHex = Self.validColor(gradientHex, default: Preferences.Default.gradientHex)
        preferences.gradientAngle = Self.normalizedAngle(gradientAngle)
        preferences.backgroundOpacity = Self.clamp(backgroundOpacity, in: limits.unitInterval,
                                                   fallback: Preferences.Default.backgroundOpacity)
        preferences.highlightHex = Self.validColor(highlightHex, default: Preferences.Default.highlightHex)
        preferences.highlightOpacity = Self.clamp(highlightOpacity, in: limits.unitInterval,
                                                  fallback: Preferences.Default.highlightOpacity)
        preferences.labelHex = Self.validColor(labelHex, default: Preferences.Default.labelHex)
        preferences.panelTypeface = PanelTypeface(rawValue: typeface)
            ?? Preferences.Default.panelTypeface
        preferences.panelCornerRadius = Self.clamp(cornerRadius, in: limits.radius,
                                                   fallback: Preferences.Default.panelCornerRadius)
        preferences.highlightCornerRadius = Self.clamp(highlightCornerRadius, in: limits.radius,
                                                       fallback: Preferences.Default.highlightCornerRadius)
        preferences.adaptiveAccent = adaptiveAccent
        preferences.decorationStyle = DecorationStyle(rawValue: decorationStyle) ?? Preferences.Default.decorationStyle
        preferences.decorationPosition = DecorationPosition(rawValue: decorationPosition) ?? Preferences.Default.decorationPosition
        preferences.decorationOpacity = Self.clamp(decorationOpacity, in: limits.unitInterval,
                                                   fallback: Preferences.Default.decorationOpacity)
        preferences.decorationSize = Self.clamp(decorationSize, in: limits.decorationSize,
                                                fallback: Preferences.Default.decorationSize)
        preferences.crtEnabled = crtEnabled
        preferences.crtIntensity = Self.clamp(crtIntensity, in: limits.unitInterval,
                                              fallback: Preferences.Default.crtIntensity)
    }

    // MARK: Validation (mirrors Preferences' own load-time validation)

    private static func clamp(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    private static func validColor(_ hex: String, default fallback: String) -> String {
        NSColor(hex: hex) != nil ? hex : fallback
    }

    private static func normalizedAngle(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }
}

// MARK: - Tolerant decoding

extension AppearancePreset {

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.Default.self
        // Every field decodes through `field`, which tolerates a *wrong JSON
        // type* as well as a missing key — `"gradientAngle": "30"` in a
        // hand-edited file must not fail the whole import.
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        name = Self.importedName(field(String.self, .name), fallback: "Imported")
        // Tolerate an *unknown* enum raw value, not just a missing key: a material
        // a future build adds would otherwise throw `dataCorrupted` and fail the
        // whole import with a misleading "not a theme" error.
        material = field(PanelMaterial.self, .material) ?? d.panelMaterial
        tintHex = field(String.self, .tintHex) ?? d.tintHex
        gradientHex = field(String.self, .gradientHex) ?? d.gradientHex
        gradientAngle = field(Double.self, .gradientAngle) ?? d.gradientAngle
        backgroundOpacity = field(Double.self, .backgroundOpacity) ?? d.backgroundOpacity
        highlightHex = field(String.self, .highlightHex) ?? d.highlightHex
        highlightOpacity = field(Double.self, .highlightOpacity) ?? d.highlightOpacity
        labelHex = field(String.self, .labelHex) ?? d.labelHex
        typeface = field(String.self, .typeface) ?? d.panelTypeface.rawValue
        cornerRadius = field(Double.self, .cornerRadius) ?? d.panelCornerRadius
        highlightCornerRadius = field(Double.self, .highlightCornerRadius) ?? d.highlightCornerRadius
        adaptiveAccent = field(Bool.self, .adaptiveAccent) ?? d.adaptiveAccent
        decorationStyle = field(String.self, .decorationStyle) ?? d.decorationStyle.rawValue
        decorationPosition = field(String.self, .decorationPosition) ?? d.decorationPosition.rawValue
        decorationOpacity = field(Double.self, .decorationOpacity) ?? d.decorationOpacity
        decorationSize = field(Double.self, .decorationSize) ?? d.decorationSize
        crtEnabled = field(Bool.self, .crtEnabled) ?? d.crtEnabled
        crtIntensity = field(Double.self, .crtIntensity) ?? d.crtIntensity
    }

    /// A usable imported name: trimmed and non-empty, else `fallback` — presets
    /// are identified (and de-duplicated in menus) by name, so an empty string
    /// can't stand. Livery's `ThemeSnapshot` applies the same rule to a
    /// sibling's theme.
    fileprivate static func importedName(_ raw: String?, fallback: String) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return fallback }
        return trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case name, material, tintHex, gradientHex, gradientAngle, backgroundOpacity
        case highlightHex, highlightOpacity, labelHex, typeface
        case cornerRadius, highlightCornerRadius, adaptiveAccent
        case decorationStyle, decorationPosition, decorationOpacity, decorationSize
        case crtEnabled, crtIntensity
    }
}

// MARK: - Import (Invoque, Jetty or Zap format)

extension AppearancePreset {

    /// Decodes a theme from JSON, accepting Invoque's own format plus **Jetty**
    /// and **Zap** theme files, so looks can be shared across the family.
    /// Livery's `ThemeSnapshot` recognises the format from keys unique to one
    /// app (the rules Invoque introduced) and reads a sibling's fields;
    /// Invoque's own decoder is fully tolerant (it never fails), so the
    /// snapshot's format decides which reader runs.
    ///
    /// JSON the snapshot does not recognise isn't a theme: it is rejected
    /// rather than letting the tolerant decoder return an all-defaults preset,
    /// so importing the wrong file surfaces an error instead of a silent swap.
    static func decode(from data: Data) -> AppearancePreset? {
        guard let theme = ThemeSnapshot(themeData: data) else { return nil }
        if theme.format == .invoque {
            return try? JSONDecoder().decode(AppearancePreset.self, from: data)
        }
        return AppearancePreset(importing: theme)
    }

    /// Maps a theme snapshot onto Invoque's settings, filling absent fields
    /// with defaults. Invoque's own files use the native decoder in `decode(from:)`.
    /// Values are validated and clamped later by `apply(to:)`.
    init(importing theme: ThemeSnapshot) {
        let d = Preferences.Default.self
        let fallbackName = switch theme.format {
        case .zap: "Zap Theme"
        case .jetty: "Jetty Theme"
        case .invoque: "Invoque Theme"
        }
        self.init(
            name: theme.name ?? fallbackName,
            material: theme.material ?? d.panelMaterial,
            tintHex: theme.tintHex ?? d.tintHex,
            gradientHex: theme.gradientHex ?? d.gradientHex,
            gradientAngle: theme.gradientAngle ?? d.gradientAngle,
            backgroundOpacity: theme.backgroundOpacity ?? d.backgroundOpacity,
            highlightHex: theme.highlightHex ?? d.highlightHex,
            highlightOpacity: theme.highlightOpacity ?? d.highlightOpacity,
            labelHex: theme.labelHex ?? d.labelHex,
            cornerRadius: theme.cornerRadius ?? d.panelCornerRadius,
            highlightCornerRadius: theme.highlightCornerRadius ?? d.highlightCornerRadius,
            adaptiveAccent: theme.adaptiveAccent ?? d.adaptiveAccent,
            decorationStyle: (theme.decorationStyle ?? d.decorationStyle).rawValue,
            decorationPosition: (theme.decorationPosition ?? d.decorationPosition).rawValue,
            decorationOpacity: theme.decorationOpacity ?? d.decorationOpacity,
            decorationSize: theme.decorationSize ?? d.decorationSize,
            crtEnabled: theme.crtEnabled ?? d.crtEnabled,
            crtIntensity: theme.crtIntensity ?? d.crtIntensity)
    }

}

// MARK: - Built-in themes

extension AppearancePreset {

    /// Ready-made themes shown in Appearance settings. The retro trio keeps the
    /// same names and values as Zap's and Jetty's so a family look means the
    /// same thing in every app.
    static let builtIns: [AppearancePreset] = [classic, summon, graphite, zxNight, vaporwave, synthwave, memphis, amiga]

    /// The shipping defaults, as a named preset.
    static let classic = AppearancePreset(
        name: "Classic",
        material: Preferences.Default.panelMaterial,
        tintHex: Preferences.Default.tintHex,
        gradientHex: Preferences.Default.gradientHex,
        gradientAngle: Preferences.Default.gradientAngle,
        backgroundOpacity: Preferences.Default.backgroundOpacity,
        highlightHex: Preferences.Default.highlightHex,
        highlightOpacity: Preferences.Default.highlightOpacity,
        labelHex: Preferences.Default.labelHex,
        cornerRadius: Preferences.Default.panelCornerRadius,
        highlightCornerRadius: Preferences.Default.highlightCornerRadius,
        adaptiveAccent: Preferences.Default.adaptiveAccent,
        decorationStyle: Preferences.Default.decorationStyle.rawValue,
        decorationPosition: Preferences.Default.decorationPosition.rawValue,
        decorationOpacity: Preferences.Default.decorationOpacity,
        decorationSize: Preferences.Default.decorationSize,
        crtEnabled: Preferences.Default.crtEnabled,
        crtIntensity: Preferences.Default.crtIntensity)

    /// Invoque's signature look — the "command cockpit": deep violet glass
    /// gradient, an electric-violet selection, and adaptive accent on so app
    /// icons still bleed their own color into the selected row.
    static let summon = AppearancePreset(
        name: "Summon",
        material: .gradient,
        tintHex: "#17122B",
        gradientHex: "#2A1F4D",
        gradientAngle: 30,
        backgroundOpacity: 0.9,
        highlightHex: "#B18CFF",
        highlightOpacity: 0.4,
        labelHex: "#EDE9FF",
        cornerRadius: 16,
        highlightCornerRadius: 10,
        adaptiveAccent: true,
        decorationStyle: DecorationStyle.none.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 10,
        crtEnabled: false,
        crtIntensity: 0.5)

    /// Flat near-black card, system-blue selection — the quiet option.
    static let graphite = AppearancePreset(
        name: "Graphite",
        material: .solid,
        tintHex: "#1C1C1E",
        gradientHex: "#2C2C2E",
        gradientAngle: 0,
        backgroundOpacity: 0.92,
        highlightHex: "#0A84FF",
        highlightOpacity: 0.4,
        labelHex: "#FFFFFF",
        cornerRadius: 16,
        highlightCornerRadius: 8,
        adaptiveAccent: false,
        decorationStyle: DecorationStyle.none.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 10,
        crtEnabled: false,
        crtIntensity: 0.5)

    static let zxNight = AppearancePreset(
        name: "ZX Night",
        material: .gradient,
        tintHex: "#0B0B1A",
        gradientHex: "#1A1140",
        gradientAngle: 20,
        backgroundOpacity: 0.85,
        highlightHex: "#00AEEF",
        highlightOpacity: 0.55,
        labelHex: "#FFFFFF",
        typeface: "menlo",
        cornerRadius: 14,
        highlightCornerRadius: 12,
        adaptiveAccent: false,
        decorationStyle: DecorationStyle.zxSpectrum.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 12,
        crtEnabled: true,
        crtIntensity: 0.5)

    static let vaporwave = AppearancePreset(
        name: "Vaporwave",
        material: .gradient,
        tintHex: "#241B4B",
        gradientHex: "#3B2A6B",
        gradientAngle: 35,
        backgroundOpacity: 0.8,
        highlightHex: "#FF6AD5",
        highlightOpacity: 0.55,
        labelHex: "#FFFFFF",
        typeface: "avenirNext",
        cornerRadius: 20,
        highlightCornerRadius: 16,
        adaptiveAccent: false,
        decorationStyle: DecorationStyle.vaporwave.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 12,
        crtEnabled: true,
        crtIntensity: 0.6)

    /// The icon art's night side (`media-sources/icon.png`): the outrun
    /// palette of navy sky, striped magenta sun and pink horizon grid.
    /// CRT on — the scanlines are part of the reference, not a novelty.
    static let synthwave = AppearancePreset(
        name: "Synthwave",
        material: .gradient,
        tintHex: "#150D33",
        gradientHex: "#341361",
        gradientAngle: 25,
        backgroundOpacity: 0.88,
        highlightHex: "#FB1A91",
        highlightOpacity: 0.5,
        labelHex: "#F5F0FF",
        typeface: "avenirNext",
        cornerRadius: 16,
        highlightCornerRadius: 10,
        adaptiveAccent: false,
        decorationStyle: DecorationStyle.synthwave.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 10,
        crtEnabled: true,
        crtIntensity: 0.5)

    /// The app icon itself (`media-sources/icon2.png`): flat Memphis Group
    /// print — cream paper, navy squiggle text, a pink wash for the
    /// selection, harder corners than the glass looks because the
    /// reference is geometry, not chrome.
    static let memphis = AppearancePreset(
        name: "Memphis",
        material: .solid,
        tintHex: "#FEFBEC",
        gradientHex: "#EFE7D5",
        gradientAngle: 0,
        backgroundOpacity: 0.97,
        highlightHex: "#FB04B5",
        highlightOpacity: 0.35,
        labelHex: "#000517",
        typeface: "futura",
        cornerRadius: 10,
        highlightCornerRadius: 6,
        adaptiveAccent: false,
        decorationStyle: DecorationStyle.memphis.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 10,
        crtEnabled: false,
        crtIntensity: 0.5)

    static let amiga = AppearancePreset(
        name: "Amiga",
        material: .solid,
        tintHex: "#1A1A1A",
        gradientHex: "#2C2C2C",
        gradientAngle: 0,
        backgroundOpacity: 0.9,
        highlightHex: "#FF6F00",
        highlightOpacity: 0.6,
        labelHex: "#FFFFFF",
        typeface: "menlo",
        cornerRadius: 16,
        highlightCornerRadius: 14,
        adaptiveAccent: false,
        // The pixel rendition: with the CRT scanlines below, the full retro look.
        decorationStyle: DecorationStyle.amigaPixel.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 10,
        crtEnabled: true,
        crtIntensity: 0.7)
}
