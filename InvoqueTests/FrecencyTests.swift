import XCTest
@testable import Invoque

final class FrecencyTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var frecency: Frecency!

    override func setUp() {
        super.setUp()
        suiteName = "InvoqueTests.Frecency.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        frecency = Frecency(defaults: defaults)
    }

    override func tearDown() {
        if let name = suiteName, let suite = defaults {
            suite.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    // MARK: Scoring

    func testFreshIDScoresZero() {
        XCTAssertEqual(frecency.score("app:com.example.Never"), 0)
    }

    func testRecordRaisesScore() {
        XCTAssertEqual(frecency.score("app:com.example.Safari"), 0)
        frecency.record("app:com.example.Safari")
        XCTAssertGreaterThan(frecency.score("app:com.example.Safari"), 0)
    }

    func testRepeatedRecordsRaiseScoreFurther() {
        frecency.record("app:com.example.Safari")
        let once = frecency.score("app:com.example.Safari")
        frecency.record("app:com.example.Safari")
        XCTAssertGreaterThan(frecency.score("app:com.example.Safari"), once)
    }

    // MARK: Persistence

    func testPersistenceRoundTrip() {
        frecency.record("app:com.example.Safari")
        let reloaded = Frecency(defaults: defaults)
        XCTAssertGreaterThan(reloaded.score("app:com.example.Safari"), 0)
    }

    // MARK: Eviction

    func testEvictionCapsEntries() {
        // 20 over the ~500-id cap: the earliest ids must be gone while a
        // recent one still scores.
        for index in 0..<520 {
            frecency.record(String(format: "id-%03d", index))
        }
        XCTAssertEqual(frecency.score("id-000"), 0)
        XCTAssertGreaterThan(frecency.score("id-519"), 0)
    }
}
