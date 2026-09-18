import AppKit
import Foundation
import ServiceManagement

/// User-facing settings, backed by `UserDefaults`.
///
/// An `ObservableObject` so SwiftUI settings views update live. A custom
/// `UserDefaults` can be injected for tests.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults: UserDefaults

    // MARK: Defaults

    enum Default {
        static let launchAtLogin = false
        static let keepQueryOnReshow = false
        static let summonHotkey = HotkeyCombination.default

        // Appearance (PLAN §9). The field names match Zap's and Jetty's where
        // the settings coincide, so theme files port between the family.
        static let panelMaterial = PanelMaterial.liquidGlass
        static let tintHex = "#1C1C1E"
        static let gradientHex = "#2C2C2E"
        static let gradientAngle = 0.0
        static let backgroundOpacity = 0.85
        static let highlightHex = "#0A84FF"
        static let highlightOpacity = 0.25
        static let labelHex = "#FFFFFF"
        static let panelCornerRadius = 16.0
        static let highlightCornerRadius = 8.0
        static let adaptiveAccent = true
        static let decorationStyle = DecorationStyle.none
        static let decorationPosition = DecorationPosition.topTrailing
        static let decorationOpacity = 1.0
        static let decorationSize = 10.0
        static let crtEnabled = false
        static let crtIntensity = 0.5
    }

    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let keepQueryOnReshow = "keepQueryOnReshow"
        static let summonHotkey = "summonHotkey"
        static let panelMaterial = "panelMaterial"
        static let tintHex = "tintHex"
        static let gradientHex = "gradientHex"
        static let gradientAngle = "gradientAngle"
        static let backgroundOpacity = "backgroundOpacity"
        static let highlightHex = "highlightHex"
        static let highlightOpacity = "highlightOpacity"
        static let labelHex = "labelHex"
        static let panelCornerRadius = "panelCornerRadius"
        static let highlightCornerRadius = "highlightCornerRadius"
        static let adaptiveAccent = "adaptiveAccent"
        static let decorationStyle = "decorationStyle"
        static let decorationPosition = "decorationPosition"
        static let decorationOpacity = "decorationOpacity"
        static let decorationSize = "decorationSize"
        static let crtEnabled = "crtEnabled"
        static let crtIntensity = "crtIntensity"
    }

    // MARK: Stored settings

    /// Whether the panel keeps its previous query when summoned again, rather
    /// than starting empty.
    @Published var keepQueryOnReshow: Bool {
        didSet { defaults.set(keepQueryOnReshow, forKey: Key.keepQueryOnReshow) }
    }

    /// The global hotkey that summons the launcher panel. Persisted as one
    /// `Codable` value (JSON in UserDefaults) so key code and modifiers can't
    /// drift apart — plain defaults can't hold a struct.
    @Published var summonHotkey: HotkeyCombination {
        didSet {
            guard oldValue != summonHotkey else { return }
            persistSummonHotkey()
            summonHotkeyChanged?(summonHotkey)
        }
    }

    /// Tells the Carbon registration's owner to re-register after a change;
    /// Preferences itself stays free of hotkey machinery. DidSet timing, so
    /// it fires after the new value is persisted (note: `@Published`
    /// subscribers are notified earlier, in willSet).
    var summonHotkeyChanged: ((HotkeyCombination) -> Void)?

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            // Persist as a fallback: init seeds from the authoritative
            // SMAppService state, but that read can fail (unsigned/test
            // contexts) and the stored value keeps the intent.
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // MARK: Appearance (PLAN §9)

    /// The card's background material — see `PanelBackground`.
    @Published var panelMaterial: PanelMaterial {
        didSet { defaults.set(panelMaterial.rawValue, forKey: Key.panelMaterial) }
    }

    /// The card's tint — the fill for `solid`, the start of `gradient`, and
    /// the tint wash for `glassTinted`.
    @Published var tintHex: String {
        didSet {
            tintHex = Self.validColor(tintHex, default: Default.tintHex)
            defaults.set(tintHex, forKey: Key.tintHex)
        }
    }

    /// The end color of the card gradient when `panelMaterial == .gradient`.
    @Published var gradientHex: String {
        didSet {
            gradientHex = Self.validColor(gradientHex, default: Default.gradientHex)
            defaults.set(gradientHex, forKey: Key.gradientHex)
        }
    }

    /// The direction the card gradient runs, in degrees from straight down
    /// (0° = top→bottom), increasing counterclockwise on screen — 90° runs
    /// left→right. Matches `AngleDial` and `PanelBackground`.
    @Published var gradientAngle: Double {
        didSet {
            gradientAngle = Self.normalizedAngle(gradientAngle)
            defaults.set(gradientAngle, forKey: Key.gradientAngle)
        }
    }

    /// Opacity of the tint/gradient (and the glass-tint wash).
    @Published var backgroundOpacity: Double {
        didSet {
            backgroundOpacity = Self.clamp(backgroundOpacity, in: Limit.unitInterval,
                                           fallback: Default.backgroundOpacity)
            defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity)
        }
    }

    /// The selection fill color — or its fallback when `adaptiveAccent` is on
    /// and the selected row's icon supplies one.
    @Published var highlightHex: String {
        didSet {
            highlightHex = Self.validColor(highlightHex, default: Default.highlightHex)
            defaults.set(highlightHex, forKey: Key.highlightHex)
        }
    }

    /// Opacity of the selection fill.
    @Published var highlightOpacity: Double {
        didSet {
            highlightOpacity = Self.clamp(highlightOpacity, in: Limit.unitInterval,
                                          fallback: Default.highlightOpacity)
            defaults.set(highlightOpacity, forKey: Key.highlightOpacity)
        }
    }

    /// Text color for row titles (secondary text derives from it at reduced
    /// opacity). Applies only on materials where the theme owns the
    /// background — see `PanelMaterial.usesThemeTextColor`.
    @Published var labelHex: String {
        didSet {
            labelHex = Self.validColor(labelHex, default: Default.labelHex)
            defaults.set(labelHex, forKey: Key.labelHex)
        }
    }

    /// The card's corner radius.
    @Published var panelCornerRadius: Double {
        didSet {
            panelCornerRadius = Self.clamp(panelCornerRadius, in: Limit.radius,
                                           fallback: Default.panelCornerRadius)
            defaults.set(panelCornerRadius, forKey: Key.panelCornerRadius)
        }
    }

    /// The selection highlight's corner radius.
    @Published var highlightCornerRadius: Double {
        didSet {
            highlightCornerRadius = Self.clamp(highlightCornerRadius, in: Limit.radius,
                                               fallback: Default.highlightCornerRadius)
            defaults.set(highlightCornerRadius, forKey: Key.highlightCornerRadius)
        }
    }

    /// Whether the selected row's icon bleeds its dominant color into the
    /// selection fill — see `AdaptiveAccent`.
    @Published var adaptiveAccent: Bool {
        didSet { defaults.set(adaptiveAccent, forKey: Key.adaptiveAccent) }
    }

    /// An optional retro corner decoration drawn on the card.
    @Published var decorationStyle: DecorationStyle {
        didSet { defaults.set(decorationStyle.rawValue, forKey: Key.decorationStyle) }
    }

    /// Which top corner `decorationStyle` is drawn in.
    @Published var decorationPosition: DecorationPosition {
        didSet { defaults.set(decorationPosition.rawValue, forKey: Key.decorationPosition) }
    }

    /// Opacity of the corner decoration.
    @Published var decorationOpacity: Double {
        didSet {
            decorationOpacity = Self.clamp(decorationOpacity, in: Limit.unitInterval,
                                           fallback: Default.decorationOpacity)
            defaults.set(decorationOpacity, forKey: Key.decorationOpacity)
        }
    }

    /// Thickness of the corner decoration's stripes / the boing ball's diameter.
    @Published var decorationSize: Double {
        didSet {
            decorationSize = Self.clamp(decorationSize, in: Limit.decorationSize,
                                        fallback: Default.decorationSize)
            defaults.set(decorationSize, forKey: Key.decorationSize)
        }
    }

    /// Whether the CRT scanline/vignette overlay draws over the card.
    @Published var crtEnabled: Bool {
        didSet { defaults.set(crtEnabled, forKey: Key.crtEnabled) }
    }

    /// Strength of the CRT overlay, 0...1.
    @Published var crtIntensity: Double {
        didSet {
            crtIntensity = Self.clamp(crtIntensity, in: Limit.unitInterval,
                                      fallback: Default.crtIntensity)
            defaults.set(crtIntensity, forKey: Key.crtIntensity)
        }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        keepQueryOnReshow = defaults.object(forKey: Key.keepQueryOnReshow) as? Bool
            ?? Default.keepQueryOnReshow

        summonHotkey = Self.loadSummonHotkey(from: defaults)

        // Seed launch-at-login from the authoritative system state rather than a
        // possibly-stale stored value, so an external change in System Settings is
        // reflected in the UI.
        launchAtLogin = Self.systemLaunchAtLoginEnabled()
            ?? (defaults.object(forKey: Key.launchAtLogin) as? Bool ?? Default.launchAtLogin)

        // Appearance — every stored value is validated the same way a preset
        // import is, so a hand-edited defaults entry can't wedge the panel.
        panelMaterial = PanelMaterial(rawValue: defaults.string(forKey: Key.panelMaterial) ?? "")
            ?? Default.panelMaterial
        tintHex = Self.validColor(defaults.string(forKey: Key.tintHex), default: Default.tintHex)
        gradientHex = Self.validColor(defaults.string(forKey: Key.gradientHex), default: Default.gradientHex)
        gradientAngle = Self.normalizedAngle(defaults.object(forKey: Key.gradientAngle) as? Double
            ?? Default.gradientAngle)
        backgroundOpacity = Self.clamp(defaults.object(forKey: Key.backgroundOpacity) as? Double
            ?? Default.backgroundOpacity, in: Limit.unitInterval, fallback: Default.backgroundOpacity)
        highlightHex = Self.validColor(defaults.string(forKey: Key.highlightHex), default: Default.highlightHex)
        highlightOpacity = Self.clamp(defaults.object(forKey: Key.highlightOpacity) as? Double
            ?? Default.highlightOpacity, in: Limit.unitInterval, fallback: Default.highlightOpacity)
        labelHex = Self.validColor(defaults.string(forKey: Key.labelHex), default: Default.labelHex)
        panelCornerRadius = Self.clamp(defaults.object(forKey: Key.panelCornerRadius) as? Double
            ?? Default.panelCornerRadius, in: Limit.radius, fallback: Default.panelCornerRadius)
        highlightCornerRadius = Self.clamp(defaults.object(forKey: Key.highlightCornerRadius) as? Double
            ?? Default.highlightCornerRadius, in: Limit.radius, fallback: Default.highlightCornerRadius)
        adaptiveAccent = defaults.object(forKey: Key.adaptiveAccent) as? Bool ?? Default.adaptiveAccent
        decorationStyle = DecorationStyle(rawValue: defaults.string(forKey: Key.decorationStyle) ?? "")
            ?? Default.decorationStyle
        decorationPosition = DecorationPosition(rawValue: defaults.string(forKey: Key.decorationPosition) ?? "")
            ?? Default.decorationPosition
        decorationOpacity = Self.clamp(defaults.object(forKey: Key.decorationOpacity) as? Double
            ?? Default.decorationOpacity, in: Limit.unitInterval, fallback: Default.decorationOpacity)
        decorationSize = Self.clamp(defaults.object(forKey: Key.decorationSize) as? Double
            ?? Default.decorationSize, in: Limit.decorationSize, fallback: Default.decorationSize)
        crtEnabled = defaults.object(forKey: Key.crtEnabled) as? Bool ?? Default.crtEnabled
        crtIntensity = Self.clamp(defaults.object(forKey: Key.crtIntensity) as? Double
            ?? Default.crtIntensity, in: Limit.unitInterval, fallback: Default.crtIntensity)
    }

    // MARK: Summon hotkey

    private func persistSummonHotkey() {
        // Two UInt32s can't realistically fail to encode; dropping the write
        // on failure just means the default returns next launch.
        guard let data = try? JSONEncoder().encode(summonHotkey) else { return }
        defaults.set(data, forKey: Key.summonHotkey)
    }

    /// Unreadable or missing stored data falls back to the default — a
    /// hand-edited defaults value must not brick summoning. A decoded value
    /// with no modifiers is rejected too: `RegisterEventHotKey` accepts a
    /// bare key, so `kVK_Space` + 0 would summon the panel on every space
    /// press system-wide.
    private static func loadSummonHotkey(from defaults: UserDefaults) -> HotkeyCombination {
        guard let data = defaults.data(forKey: Key.summonHotkey),
              let combination = try? JSONDecoder().decode(HotkeyCombination.self, from: data),
              combination.modifiers != 0
        else { return Default.summonHotkey }
        return combination
    }

    // MARK: Reset

    /// Restores every appearance preference to its factory value. The source
    /// of truth is `Default` itself — not a preset's copy of it, which could
    /// drift or lack a field added later.
    func resetAppearanceToDefaults() {
        panelMaterial = Default.panelMaterial
        tintHex = Default.tintHex
        gradientHex = Default.gradientHex
        gradientAngle = Default.gradientAngle
        backgroundOpacity = Default.backgroundOpacity
        highlightHex = Default.highlightHex
        highlightOpacity = Default.highlightOpacity
        labelHex = Default.labelHex
        panelCornerRadius = Default.panelCornerRadius
        highlightCornerRadius = Default.highlightCornerRadius
        adaptiveAccent = Default.adaptiveAccent
        decorationStyle = Default.decorationStyle
        decorationPosition = Default.decorationPosition
        decorationOpacity = Default.decorationOpacity
        decorationSize = Default.decorationSize
        crtEnabled = Default.crtEnabled
        crtIntensity = Default.crtIntensity
    }

    // MARK: Validation helpers

    /// Accepted ranges for the clamped appearance knobs — shared with
    /// `AppearancePreset.apply(to:)` so an import and a load can never
    /// disagree about what's in range.
    enum Limit {
        /// Opacities and effect intensities.
        static let unitInterval = 0.0...1.0
        /// Panel and selection-highlight corner radii.
        static let radius = 0.0...32.0
        /// Decoration stripe thickness / ball diameter.
        static let decorationSize = 4.0...30.0
    }

    /// Clamps `value` into `range`, falling back to `fallback` for non-finite
    /// (NaN/inf) input from corrupted defaults.
    private static func clamp(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// Returns `hex` if it parses to a valid color, otherwise `default`.
    private static func validColor(_ hex: String?, default fallback: String) -> String {
        guard let hex, NSColor(hex: hex) != nil else { return fallback }
        return hex
    }

    /// Wraps an angle (degrees) into `[0, 360)`, falling back to `0` for
    /// non-finite input from corrupted defaults.
    private static func normalizedAngle(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    // MARK: Launch at login

    private var isSyncingLaunchAtLogin = false

    /// Reads the real login-item state. Returns `nil` when the system can't
    /// answer (notably under XCTest, where there is no real app bundle).
    private static func systemLaunchAtLoginEnabled() -> Bool? {
        guard !TestEnvironment.isRunningTests else { return nil }
        return SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard !TestEnvironment.isRunningTests else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Invoque: failed to set launch-at-login to \(enabled): \(error)")
            // Re-sync the published value so the toggle reflects reality.
            isSyncingLaunchAtLogin = true
            launchAtLogin = Self.systemLaunchAtLoginEnabled() ?? !enabled
            isSyncingLaunchAtLogin = false
        }
    }
}
