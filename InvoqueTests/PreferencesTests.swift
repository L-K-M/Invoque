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

    func testInvalidStoredAppearanceFallsBack() {
        defaults.set("bogus", forKey: "panelMaterial")
        defaults.set("not-a-color", forKey: "highlightHex")
        defaults.set("also-not-a-color", forKey: "tintHex")
        defaults.set(4.0, forKey: "highlightOpacity")
        defaults.set(-20.0, forKey: "panelCornerRadius")
        defaults.set(730.0, forKey: "gradientAngle")
        defaults.set("nonsense", forKey: "decorationStyle")
        defaults.set(Double.nan, forKey: "crtIntensity")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.panelMaterial, Preferences.Default.panelMaterial)
        XCTAssertEqual(preferences.highlightHex, Preferences.Default.highlightHex)
        XCTAssertEqual(preferences.tintHex, Preferences.Default.tintHex)
        XCTAssertEqual(preferences.highlightOpacity, 1)
        XCTAssertEqual(preferences.panelCornerRadius, 0)
        XCTAssertEqual(preferences.gradientAngle, 10)
        XCTAssertEqual(preferences.decorationStyle, Preferences.Default.decorationStyle)
        XCTAssertEqual(preferences.crtIntensity, Preferences.Default.crtIntensity)
    }
}
