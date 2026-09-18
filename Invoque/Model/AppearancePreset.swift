import AppKit

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
        preferences.panelMaterial = material
        preferences.tintHex = Self.validColor(tintHex, default: Preferences.Default.tintHex)
        preferences.gradientHex = Self.validColor(gradientHex, default: Preferences.Default.gradientHex)
        preferences.gradientAngle = Self.normalizedAngle(gradientAngle)
        preferences.backgroundOpacity = Self.clamp(backgroundOpacity, 0, 1, Preferences.Default.backgroundOpacity)
        preferences.highlightHex = Self.validColor(highlightHex, default: Preferences.Default.highlightHex)
        preferences.highlightOpacity = Self.clamp(highlightOpacity, 0, 1, Preferences.Default.highlightOpacity)
        preferences.labelHex = Self.validColor(labelHex, default: Preferences.Default.labelHex)
        preferences.panelCornerRadius = Self.clamp(cornerRadius, 0, 32, Preferences.Default.panelCornerRadius)
        preferences.highlightCornerRadius = Self.clamp(highlightCornerRadius, 0, 32, Preferences.Default.highlightCornerRadius)
        preferences.adaptiveAccent = adaptiveAccent
        preferences.decorationStyle = DecorationStyle(rawValue: decorationStyle) ?? Preferences.Default.decorationStyle
        preferences.decorationPosition = DecorationPosition(rawValue: decorationPosition) ?? Preferences.Default.decorationPosition
        preferences.decorationOpacity = Self.clamp(decorationOpacity, 0, 1, Preferences.Default.decorationOpacity)
        preferences.decorationSize = Self.clamp(decorationSize, 4, 30, Preferences.Default.decorationSize)
        preferences.crtEnabled = crtEnabled
        preferences.crtIntensity = Self.clamp(crtIntensity, 0, 1, Preferences.Default.crtIntensity)
    }

    // MARK: Validation (mirrors Preferences' own load-time validation)

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double, _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
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
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Imported"
        // Tolerate an *unknown* enum raw value, not just a missing key: a material
        // a future build adds would otherwise throw `dataCorrupted` and fail the
        // whole import with a misleading "not a theme" error.
        material = ((try? c.decodeIfPresent(PanelMaterial.self, forKey: .material)) ?? nil) ?? d.panelMaterial
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? d.tintHex
        gradientHex = try c.decodeIfPresent(String.self, forKey: .gradientHex) ?? d.gradientHex
        gradientAngle = try c.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? d.gradientAngle
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? d.backgroundOpacity
        highlightHex = try c.decodeIfPresent(String.self, forKey: .highlightHex) ?? d.highlightHex
        highlightOpacity = try c.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? d.highlightOpacity
        labelHex = try c.decodeIfPresent(String.self, forKey: .labelHex) ?? d.labelHex
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.panelCornerRadius
        highlightCornerRadius = try c.decodeIfPresent(Double.self, forKey: .highlightCornerRadius) ?? d.highlightCornerRadius
        adaptiveAccent = try c.decodeIfPresent(Bool.self, forKey: .adaptiveAccent) ?? d.adaptiveAccent
        decorationStyle = try c.decodeIfPresent(String.self, forKey: .decorationStyle) ?? d.decorationStyle.rawValue
        decorationPosition = try c.decodeIfPresent(String.self, forKey: .decorationPosition) ?? d.decorationPosition.rawValue
        decorationOpacity = try c.decodeIfPresent(Double.self, forKey: .decorationOpacity) ?? d.decorationOpacity
        decorationSize = try c.decodeIfPresent(Double.self, forKey: .decorationSize) ?? d.decorationSize
        crtEnabled = try c.decodeIfPresent(Bool.self, forKey: .crtEnabled) ?? d.crtEnabled
        crtIntensity = try c.decodeIfPresent(Double.self, forKey: .crtIntensity) ?? d.crtIntensity
    }

    private enum CodingKeys: String, CodingKey {
        case name, material, tintHex, gradientHex, gradientAngle, backgroundOpacity
        case highlightHex, highlightOpacity, labelHex
        case cornerRadius, highlightCornerRadius, adaptiveAccent
        case decorationStyle, decorationPosition, decorationOpacity, decorationSize
        case crtEnabled, crtIntensity
    }
}

// MARK: - Import (Invoque, Jetty or Zap format)

extension AppearancePreset {

    /// Decodes a theme from JSON, accepting Invoque's own format plus **Jetty**
    /// (`material`/`tintHex`/`accentGlow`…) and **Zap** (`backgroundColorHex`/
    /// `useGradientBackground`/`highlightColorHex`…) theme files — looks can be
    /// shared across the family. Invoque's own decoder is fully tolerant (it
    /// never fails), so the raw keys are sniffed to pick a schema and the
    /// sibling's fields are mapped onto ours.
    ///
    /// A JSON object with none of the recognized keys isn't a theme — it is
    /// rejected rather than letting the tolerant decoder return an all-defaults
    /// preset, so importing the wrong file surfaces an error instead of a
    /// silent swap.
    static func decode(from data: Data) -> AppearancePreset? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let hasInvoqueKeys = obj["highlightHex"] != nil || obj["labelHex"] != nil
            || obj["adaptiveAccent"] != nil || obj["highlightOpacity"] != nil
            || obj["highlightCornerRadius"] != nil
        // `iconSize` is *not* a Jetty tell — Zap themes carry it too, so
        // including it here would mis-sniff every Zap file as Jetty's.
        let hasJettyKeys = obj["material"] != nil || obj["tintHex"] != nil
            || obj["gradientHex"] != nil || obj["tileSpacing"] != nil
            || obj["indicatorStyle"] != nil || obj["accentGlow"] != nil
            || obj["glyphHex"] != nil || obj["clockFace"] != nil
        let hasZapKeys = obj["backgroundColorHex"] != nil || obj["useGradientBackground"] != nil
            || obj["highlightColorHex"] != nil || obj["labelColorHex"] != nil
            || obj["showAppName"] != nil || obj["iconSize"] != nil
            || obj["contentPadding"] != nil

        if hasInvoqueKeys {
            return try? JSONDecoder().decode(AppearancePreset.self, from: data)
        }
        if hasJettyKeys {
            return (try? JSONDecoder().decode(JettyTheme.self, from: data))?.asInvoquePreset
        }
        if hasZapKeys {
            return (try? JSONDecoder().decode(ZapTheme.self, from: data))?.asInvoquePreset
        }
        return nil
    }
}

/// The fields of a **Jetty** theme file Invoque maps. `DockMaterial`'s raw
/// values are identical to `PanelMaterial`'s, so it crosses over directly;
/// Jetty has no per-row highlight/label — those fall to Invoque defaults.
private struct JettyTheme: Codable {
    var name: String?
    var material: String?
    var tintHex: String?
    var gradientHex: String?
    var gradientAngle: Double?
    var backgroundOpacity: Double?
    var cornerRadius: Double?
    var accentGlow: Bool?
    var decorationStyle: String?
    var decorationPosition: String?
    var decorationOpacity: Double?
    var decorationSize: Double?
    var crtEnabled: Bool?
    var crtIntensity: Double?

    var asInvoquePreset: AppearancePreset {
        let d = Preferences.Default.self
        return AppearancePreset(
            name: name ?? "Jetty Theme",
            material: material.flatMap(PanelMaterial.init(rawValue:)) ?? d.panelMaterial,
            tintHex: tintHex ?? d.tintHex,
            gradientHex: gradientHex ?? d.gradientHex,
            gradientAngle: gradientAngle ?? d.gradientAngle,
            backgroundOpacity: backgroundOpacity ?? d.backgroundOpacity,
            highlightHex: d.highlightHex,
            highlightOpacity: d.highlightOpacity,
            labelHex: d.labelHex,
            cornerRadius: cornerRadius ?? d.panelCornerRadius,
            highlightCornerRadius: d.highlightCornerRadius,
            adaptiveAccent: accentGlow ?? d.adaptiveAccent,
            decorationStyle: decorationStyle ?? d.decorationStyle.rawValue,
            decorationPosition: decorationPosition ?? d.decorationPosition.rawValue,
            decorationOpacity: decorationOpacity ?? d.decorationOpacity,
            decorationSize: decorationSize ?? d.decorationSize,
            crtEnabled: crtEnabled ?? d.crtEnabled,
            crtIntensity: crtIntensity ?? d.crtIntensity)
    }
}

/// The fields of a **Zap** theme file Invoque maps. Zap's background is a solid
/// or gradient fill (`useGradientBackground`), which lands on our `material`;
/// its `highlightColorHex`/`labelColorHex` are the same concepts as ours.
private struct ZapTheme: Codable {
    var name: String?
    var backgroundColorHex: String?
    var useGradientBackground: Bool?
    var gradientColorHex: String?
    var gradientAngle: Double?
    var backgroundOpacity: Double?
    var highlightColorHex: String?
    var highlightOpacity: Double?
    var labelColorHex: String?
    var cornerRadius: Double?
    var highlightCornerRadius: Double?
    var decorationStyle: String?
    var decorationPosition: String?
    var decorationOpacity: Double?
    var decorationSize: Double?
    var crtEnabled: Bool?
    var crtIntensity: Double?

    var asInvoquePreset: AppearancePreset {
        let d = Preferences.Default.self
        return AppearancePreset(
            name: name ?? "Zap Theme",
            material: useGradientBackground == true ? .gradient : .solid,
            tintHex: backgroundColorHex ?? d.tintHex,
            gradientHex: gradientColorHex ?? d.gradientHex,
            gradientAngle: gradientAngle ?? d.gradientAngle,
            backgroundOpacity: backgroundOpacity ?? d.backgroundOpacity,
            highlightHex: highlightColorHex ?? d.highlightHex,
            highlightOpacity: highlightOpacity ?? d.highlightOpacity,
            labelHex: labelColorHex ?? d.labelHex,
            cornerRadius: cornerRadius ?? d.panelCornerRadius,
            highlightCornerRadius: highlightCornerRadius ?? d.highlightCornerRadius,
            adaptiveAccent: d.adaptiveAccent,
            decorationStyle: decorationStyle ?? d.decorationStyle.rawValue,
            decorationPosition: decorationPosition ?? d.decorationPosition.rawValue,
            decorationOpacity: decorationOpacity ?? d.decorationOpacity,
            decorationSize: decorationSize ?? d.decorationSize,
            crtEnabled: crtEnabled ?? d.crtEnabled,
            crtIntensity: crtIntensity ?? d.crtIntensity)
    }
}

// MARK: - Built-in themes

extension AppearancePreset {

    /// Ready-made themes shown in Appearance settings. The retro trio keeps the
    /// same names and values as Zap's and Jetty's so a family look means the
    /// same thing in every app.
    static let builtIns: [AppearancePreset] = [classic, summon, graphite, zxNight, vaporwave, amiga]

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
        decorationStyle: "none",
        decorationPosition: "topTrailing",
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
        decorationStyle: "none",
        decorationPosition: "topTrailing",
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
        cornerRadius: 20,
        highlightCornerRadius: 16,
        adaptiveAccent: false,
        decorationStyle: DecorationStyle.vaporwave.rawValue,
        decorationPosition: DecorationPosition.topTrailing.rawValue,
        decorationOpacity: 1,
        decorationSize: 12,
        crtEnabled: true,
        crtIntensity: 0.6)

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
