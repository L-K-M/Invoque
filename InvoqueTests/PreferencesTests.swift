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
}
