import XCTest
@testable import Invoque

final class PreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InvoqueTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsWhenEmpty() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.keepQueryOnReshow)
        XCTAssertFalse(preferences.launchAtLogin)
    }

    func testKeepQueryOnReshowRoundTrips() {
        let preferences = Preferences(defaults: defaults)
        preferences.keepQueryOnReshow = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.keepQueryOnReshow)
    }

    func testSummonHotkeyRoundTrips() {
        let preferences = Preferences(defaults: defaults)
        preferences.summonHotkey = HotkeyCombination(keyCode: 0, modifiers: 256) // ⌘+keyCode 0

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.summonHotkey, preferences.summonHotkey)
    }

    func testModifierlessStoredHotkeyFallsBackToDefault() {
        // A bare key (no modifiers) would register globally and swallow that
        // key in every app — a corrupted or hand-edited value must not load.
        let bare = HotkeyCombination(keyCode: 49, modifiers: 0) // Space, no modifiers
        defaults.set(try! JSONEncoder().encode(bare), forKey: "summonHotkey")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.summonHotkey, .default)
    }

    func testGarbledStoredHotkeyFallsBackToDefault() {
        defaults.set("not json".data(using: .utf8), forKey: "summonHotkey")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.summonHotkey, .default)
    }

    // MARK: Appearance

    func testAppearanceDefaultsWhenEmpty() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.panelMaterial, .liquidGlass)
        XCTAssertEqual(preferences.highlightHex, "#0A84FF")
        XCTAssertTrue(preferences.adaptiveAccent)
        XCTAssertEqual(preferences.panelCornerRadius, 16)
        // Below the clamp edge, so clamp-vs-fallback stays distinguishable in
        // testInvalidStoredAppearanceFallsBack.
        XCTAssertEqual(preferences.highlightOpacity, 0.25)
        XCTAssertEqual(preferences.decorationStyle, .none)
        XCTAssertFalse(preferences.crtEnabled)
    }

    func testAppearanceRoundTrips() {
        let preferences = Preferences(defaults: defaults)
        preferences.panelMaterial = .gradient
        preferences.tintHex = "#17122B"
        preferences.highlightOpacity = 0.6
        preferences.decorationStyle = .vaporwave
        preferences.crtEnabled = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.panelMaterial, .gradient)
        XCTAssertEqual(reloaded.tintHex, "#17122B")
        XCTAssertEqual(reloaded.highlightOpacity, 0.6)
        XCTAssertEqual(reloaded.decorationStyle, .vaporwave)
        XCTAssertTrue(reloaded.crtEnabled)
    }

    /// Out-of-range repair is deliberately per-knob: angles *wrap* (730°→10°),
    /// radii/opacities/sizes *clamp* to the range edge (-20→0), and strings or
    /// enums that can't be interpreted *fall back* to defaults. Wrong-typed
    /// storage (a string where a Bool/Double belongs) can't be interpreted at
    /// all, so it takes the fallback path too.
    func testInvalidStoredAppearanceFallsBack() {
        defaults.set("bogus", forKey: "panelMaterial")
        defaults.set("not-a-color", forKey: "highlightHex")
        defaults.set("also-not-a-color", forKey: "tintHex")
        defaults.set(4.0, forKey: "highlightOpacity")
        defaults.set(-20.0, forKey: "panelCornerRadius")
        defaults.set(730.0, forKey: "gradientAngle")
        defaults.set("nonsense", forKey: "decorationStyle")
        defaults.set(Double.nan, forKey: "crtIntensity")
        // Wrong-typed garbage: a Bool read of a string yields nil, not a
        // silent false — same for Doubles.
        defaults.set("yes", forKey: "adaptiveAccent")
        defaults.set("wide", forKey: "backgroundOpacity")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.panelMaterial, Preferences.Default.panelMaterial)
        XCTAssertEqual(preferences.highlightHex, Preferences.Default.highlightHex)
        XCTAssertEqual(preferences.tintHex, Preferences.Default.tintHex)
        // 4.0 clamps to the 0...1 edge, not the default — distinguishable
        // because the default is below it.
        XCTAssertEqual(preferences.highlightOpacity, 1)
        XCTAssertNotEqual(Preferences.Default.highlightOpacity, 1)
        XCTAssertEqual(preferences.panelCornerRadius, 0)
        XCTAssertEqual(preferences.gradientAngle, 10)
        XCTAssertEqual(preferences.decorationStyle, Preferences.Default.decorationStyle)
        XCTAssertEqual(preferences.crtIntensity, Preferences.Default.crtIntensity)
        XCTAssertEqual(preferences.adaptiveAccent, Preferences.Default.adaptiveAccent)
        XCTAssertEqual(preferences.backgroundOpacity, Preferences.Default.backgroundOpacity)
    }

    /// `resetAppearanceToDefaults()` restores `Default` itself — including any
    /// field a preset struct might not carry — rather than a preset's copy.
    func testResetAppearanceToDefaults() {
        let preferences = Preferences(defaults: defaults)
        AppearancePreset.vaporwave.apply(to: preferences)
        preferences.decorationSize = 29
        preferences.resetAppearanceToDefaults()

        XCTAssertEqual(preferences.panelMaterial, Preferences.Default.panelMaterial)
        XCTAssertEqual(preferences.tintHex, Preferences.Default.tintHex)
        XCTAssertEqual(preferences.gradientHex, Preferences.Default.gradientHex)
        XCTAssertEqual(preferences.gradientAngle, Preferences.Default.gradientAngle)
        XCTAssertEqual(preferences.backgroundOpacity, Preferences.Default.backgroundOpacity)
        XCTAssertEqual(preferences.highlightHex, Preferences.Default.highlightHex)
        XCTAssertEqual(preferences.highlightOpacity, Preferences.Default.highlightOpacity)
        XCTAssertEqual(preferences.labelHex, Preferences.Default.labelHex)
        XCTAssertEqual(preferences.panelCornerRadius, Preferences.Default.panelCornerRadius)
        XCTAssertEqual(preferences.highlightCornerRadius, Preferences.Default.highlightCornerRadius)
        XCTAssertEqual(preferences.adaptiveAccent, Preferences.Default.adaptiveAccent)
        XCTAssertEqual(preferences.decorationStyle, Preferences.Default.decorationStyle)
        XCTAssertEqual(preferences.decorationPosition, Preferences.Default.decorationPosition)
        XCTAssertEqual(preferences.decorationOpacity, Preferences.Default.decorationOpacity)
        XCTAssertEqual(preferences.decorationSize, Preferences.Default.decorationSize)
        XCTAssertEqual(preferences.crtEnabled, Preferences.Default.crtEnabled)
        XCTAssertEqual(preferences.crtIntensity, Preferences.Default.crtIntensity)
    }

    /// A direct setter can't persist an out-of-range or unparseable value —
    /// the `didSet` sanitizes before writing, not just on next launch.
    func testSettersSanitizeBeforePersisting() {
        let preferences = Preferences(defaults: defaults)
        preferences.backgroundOpacity = 4
        preferences.panelCornerRadius = -20
        preferences.tintHex = "not-a-color"
        preferences.gradientAngle = 730

        XCTAssertEqual(preferences.backgroundOpacity, 1)
        XCTAssertEqual(preferences.panelCornerRadius, 0)
        XCTAssertEqual(preferences.tintHex, Preferences.Default.tintHex)
        XCTAssertEqual(preferences.gradientAngle, 10)
        XCTAssertEqual(defaults.double(forKey: "backgroundOpacity"), 1)
        XCTAssertEqual(defaults.string(forKey: "tintHex"), Preferences.Default.tintHex)
    }
}
