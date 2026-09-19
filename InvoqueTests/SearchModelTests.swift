import XCTest
@testable import Invoque

final class SearchModelTests: XCTestCase {

    /// In-memory source with canned items for aggregation tests. Records
    /// the queries it receives so forwarding is verifiable.
    private final class StubSource: ItemSource {
        var stubbedItems: [Item] = []
        private(set) var receivedQueries: [String] = []
        func items(matching query: String) -> [Item] {
            receivedQueries.append(query)
            return stubbedItems
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "InvoqueTests.SearchModel.\(UUID().uuidString)"
        defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "Could not create test UserDefaults suite"
        )
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
            icon: .appIcon(path: "/Applications/\(title).app", bundleID: nil),
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
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map { $0.id }), Set(["app:safari", "app:terminal"]))
        XCTAssertEqual(first.receivedQueries, ["r"])
        XCTAssertEqual(second.receivedQueries, ["r"])
    }

    func testDuplicateIdsAcrossSourcesCollapse() {
        let first = StubSource()
        first.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let second = StubSource()
        second.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let results = makeModel(sources: [first, second]).results(for: "safari")
        XCTAssertEqual(results.count, 1)
    }

    func testDuplicatePinnedIdsCollapse() {
        // Pinned rows bypass the fuzzy scoring path, but identical ids
        // must still collapse to a single row.
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "calc:2+2", title: "= 4"),
            Self.appItem(id: "calc:2+2", title: "= 4"),
        ]
        let results = makeModel(sources: [source]).results(for: "2+2")
        XCTAssertEqual(results.count, 1)
    }

    func testNonMatchingItemsFiltered() {
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        XCTAssertTrue(makeModel(sources: [source]).results(for: "zzz").isEmpty)
    }

    func testInvisibleKeywordInMatchTextSurfacesItem() {
        // Command rows carry keywords that aren't in the title — matching
        // runs against matchText, so "pretty" must find "Format JSON".
        let item = Item(
            id: "cmd:fmt-json",
            title: "Format JSON",
            subtitle: "Command",
            icon: .symbol("terminal"),
            action: .runCommand("fmt-json", []),
            matchText: "Format JSON pretty json fmt-json")
        let source = StubSource()
        source.stubbedItems = [item]
        XCTAssertEqual(makeModel(sources: [source]).results(for: "pretty")
            .map(\.id), ["cmd:fmt-json"])
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

    func testRepeatedSelectionsPromoteItem() {
        // "Norse" and "North" tie on every ranking key for "no" — same
        // tier (both prefix), same length — and "Norse" wins the title
        // tiebreak unaided, so only frecency can flip the order.
        let source = StubSource()
        let norse = Self.appItem(id: "app:norse", title: "Norse")
        let north = Self.appItem(id: "app:north", title: "North")
        source.stubbedItems = [norse, north]
        let model = makeModel(sources: [source])
        // No frecency yet: the documented title/id tiebreak is the order.
        XCTAssertEqual(model.results(for: "no").map(\.id),
                       ["app:norse", "app:north"])
        model.recordSelection(north)
        model.recordSelection(north)
        XCTAssertEqual(model.results(for: "no").first?.id, "app:north")
    }

    /// The discriminating case for tier-over-score ordering: "a b" scores
    /// higher for "ab" on the raw alignment (two word-start bonuses) but
    /// only fuzzy-matches — the contiguous infix still wins on tier.
    func testInfixBeatsHigherScoredFuzzy() {
        let source = StubSource()
        let fuzzy = Self.appItem(id: "app:fuzzy", title: "a b")
        let infix = Self.appItem(id: "app:infix", title: "wxyzabq")
        source.stubbedItems = [fuzzy, infix]
        // Guard the premise: the fuzzy hit really does out-score the infix.
        let fuzzyScore = FuzzyMatcher.score("ab", candidate: "a b")
        let infixScore = FuzzyMatcher.score("ab", candidate: "wxyzabq")
        XCTAssertGreaterThan(fuzzyScore ?? 0, infixScore ?? 0)
        XCTAssertEqual(makeModel(sources: [source]).results(for: "ab")
            .map(\.id), ["app:infix", "app:fuzzy"])
    }

    /// Ranking is class-first: an exact prefix beats an infix beats a
    /// fuzzy subsequence, and a shorter matched text wins inside a class —
    /// before score or frecency get a say.
    func testPrefixBeatsInfixRegardlessOfLength() {
        // "Asaf" is the shorter candidate but only an infix of "saf";
        // tier beats length, so the prefix hit still leads.
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:asaf", title: "Asaf"),
            Self.appItem(id: "app:safarix", title: "SafariX"),
        ]
        XCTAssertEqual(makeModel(sources: [source]).results(for: "saf")
            .map(\.id), ["app:safarix", "app:asaf"])
    }

    func testInfixBeatsFuzzyRegardlessOfLength() {
        // "SanFran" is shorter but only fuzzy-matches "saf" (s…a…f, no
        // contiguous hit); the longer infix still leads.
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:sanfran", title: "SanFran"),
            Self.appItem(id: "app:xsafthing", title: "x-saf-thing"),
        ]
        XCTAssertEqual(makeModel(sources: [source]).results(for: "saf")
            .map(\.id), ["app:xsafthing", "app:sanfran"])
    }

    func testShorterMatchWinsWithinTier() {
        // Both are prefix hits of "sa"; the shorter match text leads even
        // though both earn the same prefix bonus.
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:safari", title: "Safari"),
            Self.appItem(id: "app:sa", title: "Sa"),
        ]
        XCTAssertEqual(makeModel(sources: [source]).results(for: "sa")
            .map(\.id), ["app:sa", "app:safari"])
    }

    func testSelectionOfPinnedRowsIsNotRecorded() {
        // web:/calc: ids embed the raw query and are never fuzzy-scored —
        // recording them would persist queries and evict real history.
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let model = makeModel(sources: [source, WebSource(), CalculatorSource()])
        let webItems = model.results(for: "safari")
            .filter { $0.id.hasPrefix(Item.webIDPrefix) }
        let calcItems = model.results(for: "2+2")
            .filter { $0.id.hasPrefix(Item.calculatorIDPrefix) }
        // Guard against a vacuous pass: the filters must actually find rows.
        XCTAssertFalse(webItems.isEmpty)
        XCTAssertFalse(calcItems.isEmpty)
        webItems.forEach(model.recordSelection)
        calcItems.forEach(model.recordSelection)
        XCTAssertNil(defaults.data(forKey: "SearchFrecency.v1"))
        model.recordSelection(Self.appItem(id: "app:safari", title: "Safari"))
        XCTAssertNotNil(defaults.data(forKey: "SearchFrecency.v1"))
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
