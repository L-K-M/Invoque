import XCTest
@testable import Invoque

/// The publish/retire predicate behind "Test connection": a late
/// completion only shows while the key it described is still the stored
/// key or the current draft.
final class SettingsViewTests: XCTestCase {

    /// The draft under test never changed — publish.
    func testPublishesWhenDraftUnchanged() {
        XCTAssertTrue(SettingsView.shouldPublishTestResult(
            testedKey: "k2", storedKey: "k1", draft: "k2"))
    }

    /// Saving the tested draft stores it — publish via the stored key.
    func testPublishesAfterSavingTestedDraft() {
        XCTAssertTrue(SettingsView.shouldPublishTestResult(
            testedKey: "k2", storedKey: "k2", draft: ""))
    }

    /// The draft was edited mid-flight and the stored key differs —
    /// retire.
    func testRetiresWhenDraftEdited() {
        XCTAssertFalse(SettingsView.shouldPublishTestResult(
            testedKey: "k2", storedKey: "k1", draft: "k3"))
    }

    /// Remove cleared the stored key and the draft no longer matches —
    /// retire.
    func testRetiresAfterRemove() {
        XCTAssertFalse(SettingsView.shouldPublishTestResult(
            testedKey: "k1", storedKey: "", draft: ""))
    }

    /// Testing the stored key with an untouched empty draft publishes.
    func testPublishesStoredKeyTest() {
        XCTAssertTrue(SettingsView.shouldPublishTestResult(
            testedKey: "k1", storedKey: "k1", draft: ""))
    }

    /// Keyless providers test with no key at all — the empty sentinels
    /// still agree, so the result publishes.
    func testPublishesKeylessTest() {
        XCTAssertTrue(SettingsView.shouldPublishTestResult(
            testedKey: "", storedKey: "", draft: ""))
    }
}
