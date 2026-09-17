import XCTest
@testable import Invoque

final class SearchModelTests: XCTestCase {

    /// In-memory source with canned items for aggregation tests.
    private final class StubSource: ItemSource {
        var stubbedItems: [Item] = []
        func items(matching query: String) -> [Item] { stubbedItems }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InvoqueTests.SearchModel.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() {
        if let name = suiteName, let suite = defaults {
            suite.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    // MARK: Helpers

    private func makeModel(sources: [ItemSource]) -> SearchModel {
        SearchModel(sources: sources, frecency: Frecency(defaults: defaults))
    }

    private static func appItem(id: String, title: String) -> Item {
        Item(
            id: id,
            title: title,
            subtitle: "Application",
            icon: .appIcon("/Applications/\(title).app"),
            action: .openApp(URL(fileURLWithPath: "/Applications/\(title).app")),
            matchText: title
        )
    }

    // MARK: Aggregation

    func testEmptyQueryYieldsNoResults() {
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        XCTAssertTrue(makeModel(sources: [source]).results(for: "").isEmpty)
        XCTAssertTrue(makeModel(sources: [source]).results(for: "   ").isEmpty)
    }

    func testAggregatesAcrossSources() {
        let first = StubSource()
        first.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let second = StubSource()
        second.stubbedItems = [Self.appItem(id: "app:terminal", title: "Terminal")]
        let results = makeModel(sources: [first, second]).results(for: "r")
        XCTAssertEqual(Set(results.map { $0.id }), Set(["app:safari", "app:terminal"]))
    }

    func testNonMatchingItemsFiltered() {
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        XCTAssertTrue(makeModel(sources: [source]).results(for: "zzz").isEmpty)
    }

    // MARK: Ranking

    func testFrecencyBreaksTies() {
        // Identical match text means identical fuzzy scores, so the recorded
        // pick must sort first.
        let source = StubSource()
        let first = Self.appItem(id: "app:first", title: "Duplicate")
        let second = Self.appItem(id: "app:second", title: "Duplicate")
        source.stubbedItems = [first, second]
        let model = makeModel(sources: [source])
        model.recordSelection(second)
        let results = model.results(for: "dup")
        XCTAssertEqual(results.first?.id, "app:second")
    }

    func testCalculatorOutranksFuzzyNoise() {
        // Even an app whose name matches the digits must not beat `= 4`.
        let apps = StubSource()
        apps.stubbedItems = [Self.appItem(id: "app:spoiler", title: "2 + 2 = 5")]
        let model = makeModel(sources: [apps, CalculatorSource()])
        let results = model.results(for: "2+2")
        XCTAssertEqual(results.first?.id, "calc:2+2")
    }

    func testWebFallbackSortsLast() {
        let apps = StubSource()
        apps.stubbedItems = [Self.appItem(id: "app:com.apple.Safari", title: "Safari")]
        let model = makeModel(sources: [apps, WebSource()])
        let results = model.results(for: "safari")
        XCTAssertEqual(results.first?.id, "app:com.apple.Safari")
        XCTAssertEqual(results.last?.id, "web:safari")
    }

    func testResultsCappedAtFifty() {
        let source = StubSource()
        source.stubbedItems = (0..<60).map { index in
            Self.appItem(id: "app:item-\(index)", title: "Test Item \(index)")
        }
        let results = makeModel(sources: [source]).results(for: "test")
        XCTAssertEqual(results.count, SearchModel.maxResults)
    }

    func testWebFallbackKeepsSlotWhenRankedFillsCap() {
        // A noisy ranked list must not push the pinned web row past the cap —
        // exactly when local matching is weak the fallback is most needed.
        let apps = StubSource()
        apps.stubbedItems = (0..<60).map { index in
            Self.appItem(id: "app:safari-\(index)", title: "Safari \(index)")
        }
        let model = makeModel(sources: [apps, WebSource()])
        let results = model.results(for: "safari")
        XCTAssertEqual(results.count, SearchModel.maxResults)
        XCTAssertEqual(results.last?.id, "web:safari")
    }
}
