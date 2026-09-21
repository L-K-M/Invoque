import XCTest
@testable import Invoque

final class QueryHistoryTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InvoqueTests.QueryHistory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let name = suiteName, let suite = defaults {
            suite.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    // MARK: Recording

    func testRecordsMostRecentFirst() {
        let history = QueryHistory(defaults: defaults)
        history.record("alpha")
        history.record("beta")
        XCTAssertEqual(history.entries, ["beta", "alpha"])
    }

    func testBlankQueriesNeverRecord() {
        let history = QueryHistory(defaults: defaults)
        history.record("")
        history.record("   ")
        XCTAssertTrue(history.entries.isEmpty)
    }

    /// Re-submitting the current front entry (a recalled query, say) must
    /// not duplicate it.
    func testConsecutiveRepeatIsANoOp() {
        let history = QueryHistory(defaults: defaults)
        history.record("alpha")
        history.record("alpha")
        XCTAssertEqual(history.entries, ["alpha"])
    }

    /// A repeat that isn't consecutive moves to the front without
    /// duplicating.
    func testNonConsecutiveRepeatMovesToFront() {
        let history = QueryHistory(defaults: defaults)
        history.record("alpha")
        history.record("beta")
        history.record("alpha")
        XCTAssertEqual(history.entries, ["alpha", "beta"])
    }

    func testCapsAtFifty() {
        let history = QueryHistory(defaults: defaults)
        for index in 0..<60 {
            history.record("query-\(index)")
        }
        XCTAssertEqual(history.entries.count, 50)
        XCTAssertEqual(history.entries.first, "query-59")
        XCTAssertEqual(history.entries.last, "query-10")
    }

    // MARK: Persistence

    func testPersistenceRoundTrip() {
        QueryHistory(defaults: defaults).record("alpha")
        let reloaded = QueryHistory(defaults: defaults)
        XCTAssertEqual(reloaded.entries, ["alpha"])
    }

    /// A corrupted store resets rather than wedging recall — the same
    /// recovery frecency applies.
    func testCorruptedStoreResets() {
        defaults.set(Data([0xFF, 0xFE]), forKey: "PanelQueryHistory.v1")
        let history = QueryHistory(defaults: defaults)
        XCTAssertTrue(history.entries.isEmpty)
        // And it stays writable afterwards.
        history.record("alpha")
        XCTAssertEqual(QueryHistory(defaults: defaults).entries, ["alpha"])
    }
}
