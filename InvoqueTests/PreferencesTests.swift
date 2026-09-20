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

    // MARK: Pinned & blocked entries

    func testPinnedBlockedDefaultEmpty() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.pinnedItems.isEmpty)
        XCTAssertTrue(preferences.blockedItems.isEmpty)
    }

    func testPinnedItemsRoundTrip() {
        let preferences = Preferences(defaults: defaults)
        preferences.togglePinned(id: "app:com.apple.Safari", title: "Safari")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.pinnedItems, ["app:com.apple.Safari": "Safari"])
        XCTAssertTrue(reloaded.isPinned("app:com.apple.Safari"))
        XCTAssertFalse(reloaded.isBlocked("app:com.apple.Safari"))
    }

    func testTogglePinnedToggles() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.togglePinned(id: "cmd:fmt", title: "Format JSON"))
        XCTAssertTrue(preferences.isPinned("cmd:fmt"))
        XCTAssertFalse(preferences.togglePinned(id: "cmd:fmt", title: "Format JSON"))
        XCTAssertFalse(preferences.isPinned("cmd:fmt"))
        XCTAssertTrue(preferences.pinnedItems.isEmpty)
    }

    /// Blocking a pinned entry must clear the pin — otherwise unblocking
    /// would silently resurrect it.
    func testToggleBlockedUnpins() {
        let preferences = Preferences(defaults: defaults)
        preferences.togglePinned(id: "app:x", title: "X")
        XCTAssertTrue(preferences.toggleBlocked(id: "app:x", title: "X"))
        XCTAssertTrue(preferences.isBlocked("app:x"))
        XCTAssertFalse(preferences.isPinned("app:x"))

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.isBlocked("app:x"))
        XCTAssertFalse(reloaded.isPinned("app:x"))

        // Unblocking leaves the entry fully unmanaged.
        XCTAssertFalse(reloaded.toggleBlocked(id: "app:x", title: "X"))
        XCTAssertFalse(reloaded.isBlocked("app:x"))
        XCTAssertFalse(reloaded.isPinned("app:x"))
    }

    /// The sets are exclusive in both directions: pinning a blocked entry
    /// unblocks it, the mirror of `toggleBlocked` unpinning. Unreachable
    /// through the UI (a blocked row can't be selected), but a hand edit
    /// or future caller gets a defined semantic — last action wins.
    func testTogglePinnedUnblocks() {
        let preferences = Preferences(defaults: defaults)
        preferences.toggleBlocked(id: "app:x", title: "X")
        XCTAssertTrue(preferences.togglePinned(id: "app:x", title: "X"))
        XCTAssertTrue(preferences.isPinned("app:x"))
        XCTAssertFalse(preferences.isBlocked("app:x"))

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.isPinned("app:x"))
        XCTAssertFalse(reloaded.isBlocked("app:x"))
    }

    /// `entryRulesChanged` fires on writes to either set — the panel's
    /// live refresh depends on it. The pin-clearing half of a block fires
    /// twice (pin removal + block insert); only non-zero is asserted.
    func testEntryRulesChangedFires() {
        let preferences = Preferences(defaults: defaults)
        var fired = 0
        preferences.entryRulesChanged = { fired += 1 }
        preferences.togglePinned(id: "app:x", title: "X")
        XCTAssertGreaterThan(fired, 0)
        let afterPin = fired
        preferences.toggleBlocked(id: "app:x", title: "X")
        XCTAssertGreaterThan(fired, afterPin)
        let afterBlock = fired
        // Direct dictionary writes (the Settings list's remove path) fire too.
        preferences.blockedItems["app:x"] = nil
        XCTAssertGreaterThan(fired, afterBlock)
    }

    /// A hand-edited dict with a non-string value keeps its valid entries —
    /// `compactMapValues` drops the malformed one rather than the list.
    func testMalformedPinEntriesDropIndividually() {
        defaults.set(["app:ok": "OK", "app:bad": 42], forKey: "pinnedItems")
        defaults.set("not a dict", forKey: "blockedItems")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.pinnedItems, ["app:ok": "OK"])
        XCTAssertTrue(preferences.blockedItems.isEmpty)
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
