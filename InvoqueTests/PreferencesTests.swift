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
}
