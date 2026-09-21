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

    private static func appItem(id: String, title: String,
                                matchText: String? = nil) -> Item {
        Item(
            id: id,
            title: title,
            subtitle: "Application",
            icon: .appIcon(path: "/Applications/\(title).app", bundleID: nil),
            action: .openApp(URL(fileURLWithPath: "/Applications/\(title).app")),
            matchText: matchText ?? title
        )
    }

    /// Rules stub for pin/block tests — the `Preferences`-backed closures
    /// production uses, replaced by sets the test mutates directly.
    private final class StubRules {
        var pinned = Set<String>()
        var blocked = Set<String>()
        var entryRules: EntryRules {
            EntryRules(isPinned: { [self] in pinned.contains($0) },
                       isBlocked: { [self] in blocked.contains($0) })
        }
    }

    private func makeModel(sources: [ItemSource],
                           rules: StubRules) -> SearchModel {
        SearchModel(sources: sources, frecency: Frecency(defaults: defaults),
                    entryRules: rules.entryRules)
    }

    // MARK: Aggregation

    func testEmptyQueryWithNoFrecencyHistoryYieldsNoResults() {
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        // No recorded picks → no top hits: a zero-state user sees the
        // panel's input hint, not an arbitrary app list.
        XCTAssertTrue(makeModel(sources: [source]).results(for: "").isEmpty)
        XCTAssertTrue(makeModel(sources: [source]).results(for: "   ").isEmpty)
    }

    // MARK: Empty-query top hits

    func testEmptyQueryReturnsFrecencyTopHits() {
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:safari", title: "Safari"),
            Self.appItem(id: "app:terminal", title: "Terminal"),
        ]
        let frecency = Frecency(defaults: defaults)
        frecency.record("app:terminal")
        frecency.record("app:terminal")
        frecency.record("app:safari")
        let model = SearchModel(sources: [source], frecency: frecency)
        // Higher visit count leads — the rail is "most used", not alphabet.
        XCTAssertEqual(model.results(for: "").map(\.id),
                       ["app:terminal", "app:safari"])
    }

    func testBlankQueryBehavesLikeEmpty() {
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let frecency = Frecency(defaults: defaults)
        frecency.record("app:safari")
        let model = SearchModel(sources: [source], frecency: frecency)
        XCTAssertEqual(model.results(for: "  ").map(\.id), ["app:safari"])
    }

    func testTopHitsExcludeUnrecordedItems() {
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:recorded", title: "Recorded"),
            Self.appItem(id: "app:never-launched", title: "Never Launched"),
        ]
        let frecency = Frecency(defaults: defaults)
        frecency.record("app:recorded")
        let model = SearchModel(sources: [source], frecency: frecency)
        XCTAssertEqual(model.results(for: "").map(\.id), ["app:recorded"])
    }

    func testTopHitsCapAtNineInScoreOrder() {
        let source = StubSource()
        source.stubbedItems = (0..<12).map { index in
            Self.appItem(id: String(format: "app:%02d", index),
                         title: String(format: "App %02d", index))
        }
        let frecency = Frecency(defaults: defaults)
        for index in 0..<12 {
            frecency.record(String(format: "app:%02d", index))
        }
        // One extra pick breaks the tie at the top: item 11 leads.
        frecency.record("app:11")
        let model = SearchModel(sources: [source], frecency: frecency)
        let results = model.results(for: "")
        XCTAssertEqual(results.count, SearchModel.maxTopHits)
        XCTAssertEqual(results.first?.id, "app:11")
        // The single-visit tail: the decay multiplier reads wall-clock time,
        // so within equal visit counts the more recently recorded scores
        // marginally higher — the tail is reverse recording order (the
        // title/id tie-break only fires on exactly equal scores, e.g.
        // decay-floored entries a month old). Items 00–02 fall past the cap.
        // Compared as a set: membership is the cap's contract, and the
        // within-tail order is covered separately below without depending
        // on sub-millisecond timestamps landing in recording order.
        XCTAssertEqual(Set(results.dropFirst().map(\.id)),
                       Set((3...10).map { String(format: "app:%02d", $0) }))
    }

    /// Within equal visit counts, the more recently recorded entry leads —
    /// the decay multiplier makes "same number of uses" order by last use.
    /// A millisecond between the records keeps the ordering assertion
    /// clear of any clock-resolution coincidence.
    func testTopHitsOrderSingleVisitsByRecency() {
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:first-recorded", title: "Aaa"),
            Self.appItem(id: "app:last-recorded", title: "Zzz"),
        ]
        let frecency = Frecency(defaults: defaults)
        frecency.record("app:first-recorded")
        Thread.sleep(forTimeInterval: 0.001)
        frecency.record("app:last-recorded")
        let model = SearchModel(sources: [source], frecency: frecency)
        XCTAssertEqual(model.results(for: "").map(\.id),
                       ["app:last-recorded", "app:first-recorded"])
    }

    /// A transient id recorded straight into frecency (a hand-edited
    /// defaults file, say) must not surface — the rail serves durable,
    /// user-meaningful entries only.
    func testTopHitsExcludeTransientIDs() {
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "web:safari", title: "Row")]
        let frecency = Frecency(defaults: defaults)
        frecency.record("web:safari")
        let model = SearchModel(sources: [source], frecency: frecency)
        XCTAssertTrue(model.results(for: "").isEmpty)
    }

    func testTopHitsHonorBlocks() {
        let rules = StubRules()
        rules.blocked = ["app:terminal"]
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:safari", title: "Safari"),
            Self.appItem(id: "app:terminal", title: "Terminal"),
        ]
        let frecency = Frecency(defaults: defaults)
        frecency.record("app:safari")
        frecency.record("app:terminal")
        frecency.record("app:terminal")
        let model = SearchModel(sources: [source], frecency: frecency,
                                entryRules: rules.entryRules)
        XCTAssertEqual(model.results(for: "").map(\.id), ["app:safari"])
    }

    func testTopHitsDeduplicateIdsAcrossSources() {
        let first = StubSource()
        first.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let second = StubSource()
        second.stubbedItems = [Self.appItem(id: "app:safari", title: "Safari")]
        let frecency = Frecency(defaults: defaults)
        frecency.record("app:safari")
        let model = SearchModel(sources: [first, second], frecency: frecency)
        XCTAssertEqual(model.results(for: "").count, 1)
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

    /// "Shorter wins" measures the displayed title, not the match
    /// surface — an app whose file name is longer than its display name
    /// ("Zen" from `Zen Browser.app` → matchText "Zen Zen Browser") must
    /// not lose to a longer-titled rival.
    func testShorterTitleBeatsLongerMatchText() {
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:zenmap", title: "Zenmap",
                         matchText: "Zenmap Zenmap"),
            Self.appItem(id: "app:zen", title: "Zen",
                         matchText: "Zen Zen Browser"),
        ]
        XCTAssertEqual(makeModel(sources: [source]).results(for: "zen")
            .map(\.id), ["app:zen", "app:zenmap"])
    }

    /// A hit that only lives in the hidden match surface (file name,
    /// keywords) must not outrank a same-tier hit the user can see —
    /// short title or not.
    func testVisibleTitleMatchBeatsHiddenMatchTextHit() {
        let source = StubSource()
        source.stubbedItems = [
            // "rowser" is an infix of "Zen Zen Browser" but absent from
            // the displayed "Zen" title.
            Self.appItem(id: "app:zen", title: "Zen",
                         matchText: "Zen Zen Browser"),
            // 24-char title vs the hidden item's 15-char matchText:
            // under the old matchText-length rule "Zen" would lead, so
            // only the matchedInTitle flag produces this order.
            Self.appItem(id: "app:webbrowser",
                         title: "Web Browser Professional"),
        ]
        XCTAssertEqual(makeModel(sources: [source]).results(for: "rowser")
            .map(\.id), ["app:webbrowser", "app:zen"])
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

    /// A typed/pasted path pins *first* — ahead of the calculator and
    /// every fuzzy match — because a filesystem address is a direct intent,
    /// not a search term.
    func testPathRowPinsFirst() {
        let source = StubSource()
        source.stubbedItems = [
            // An exact-prefix match — the spoiler must actually rank for
            // the pin-over-ranked assertion to mean anything.
            Self.appItem(id: "app:spoiler", title: "/tmp"),
            Self.appItem(id: "calc:2+2", title: "= 4"),
        ]
        let model = makeModel(sources: [source, PathSource()])
        let results = model.results(for: "/tmp")
        // calc: ids pin without matching — the spoiler is live, so the
        // explicit order assertion is the path-over-calc guarantee.
        XCTAssertEqual(Array(results.map(\.id).prefix(3)),
                       ["path:/tmp", "calc:2+2", "app:spoiler"])
        XCTAssertEqual(results.first?.action,
                       .openFile(URL(fileURLWithPath: "/tmp")))
    }

    /// The path pin reserves its slot the same as calc/web — a noisy ranked
    /// list can't push it off the page.
    func testPathRowKeepsSlotWhenRankedFillsCap() {
        let apps = StubSource()
        apps.stubbedItems = (0..<60).map { index in
            // Titles must contain the query's leading "/" to match at all —
            // otherwise the ranked list never fills and the test is vacuous.
            Self.appItem(id: "app:item-\(index)", title: "/tmp\(index)")
        }
        let model = makeModel(sources: [apps, PathSource()])
        let results = model.results(for: "/tmp")
        XCTAssertEqual(results.first?.id, "path:/tmp")
        XCTAssertEqual(results.count, SearchModel.maxResults)
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

    // MARK: Pinned & blocked entries

    /// A pinned entry leads the ranked list even when an unpinned match
    /// outranks it on every signal — pin is a boost, not a sort key.
    func testPinnedEntryLeadsRankedMatches() {
        let rules = StubRules()
        rules.pinned = ["app:loser"]
        let source = StubSource()
        source.stubbedItems = [
            // Prefix hit — strictly outranks the fuzzy-only pinned item.
            Self.appItem(id: "app:winner", title: "Safari"),
            Self.appItem(id: "app:loser", title: "SanFran"),
        ]
        let model = makeModel(sources: [source], rules: rules)
        XCTAssertEqual(model.results(for: "saf").map(\.id),
                       ["app:loser", "app:winner"])
    }

    /// A pin boosts a matching entry; it never conjures one — a pinned id
    /// that fails the query must not appear.
    func testPinnedEntryMustStillMatch() {
        let rules = StubRules()
        rules.pinned = ["app:pinned"]
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:pinned", title: "Terminal"),
            Self.appItem(id: "app:plain", title: "Safari"),
        ]
        let model = makeModel(sources: [source], rules: rules)
        XCTAssertEqual(model.results(for: "saf").map(\.id), ["app:plain"])
    }

    /// Pins keep their rank order among themselves — the band is a boost
    /// over the unpinned, not a scramble of the pinned.
    func testPinnedBandKeepsRankOrder() {
        let rules = StubRules()
        rules.pinned = ["app:second", "app:first"]
        let source = StubSource()
        source.stubbedItems = [
            // "Sa" outranks "Safari" (shorter prefix hit); pinning both
            // must keep that order inside the band.
            Self.appItem(id: "app:second", title: "Safari"),
            Self.appItem(id: "app:first", title: "Sa"),
            Self.appItem(id: "app:plain", title: "Sabre"),
        ]
        let model = makeModel(sources: [source], rules: rules)
        XCTAssertEqual(model.results(for: "sa").map(\.id),
                       ["app:first", "app:second", "app:plain"])
    }

    /// The pin band sits under the functional head pins: a live `calc:`
    /// row still leads a user-pinned entry on the same query.
    func testPinnedBandSitsUnderCalculatorPin() {
        let rules = StubRules()
        rules.pinned = ["app:pinned"]
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:pinned", title: "Safari"),
            Self.appItem(id: "app:plain", title: "Sabre"),
            // StubSource emits this on every query; functional pins
            // classify by id prefix without matching, so it leads "sa".
            Self.appItem(id: "calc:1+1", title: "= 2"),
        ]
        let model = makeModel(sources: [source], rules: rules)
        XCTAssertEqual(model.results(for: "sa").map(\.id),
                       ["calc:1+1", "app:pinned", "app:plain"])
    }

    /// Same for the leading pin: a typed path still outranks a pinned
    /// entry that matches it.
    func testPinnedBandSitsUnderPathPin() {
        let rules = StubRules()
        rules.pinned = ["app:pinned"]
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:pinned", title: "/tmp tool")]
        let model = makeModel(sources: [source, PathSource()], rules: rules)
        XCTAssertEqual(model.results(for: "/tmp").map(\.id),
                       ["path:/tmp", "app:pinned"])
    }

    /// Pinned entries draw from the same cap: they can't push the web
    /// fallback off, and the total stays at `maxResults`.
    func testPinnedEntriesKeepWebSlotWhenRankedFillsCap() {
        let rules = StubRules()
        rules.pinned = ["app:safari-0", "app:safari-1", "app:safari-2"]
        let apps = StubSource()
        apps.stubbedItems = (0..<60).map { index in
            Self.appItem(id: "app:safari-\(index)", title: "Safari \(index)")
        }
        let model = makeModel(sources: [apps, WebSource()], rules: rules)
        let results = model.results(for: "safari")
        XCTAssertEqual(results.count, SearchModel.maxResults)
        XCTAssertEqual(Array(results.map(\.id).prefix(3)),
                       ["app:safari-0", "app:safari-1", "app:safari-2"])
        XCTAssertEqual(results.last?.id, "web:safari")
    }

    /// Block is absolute: a matching entry simply never appears, however
    /// strong its rank.
    func testBlockedEntryNeverAppears() {
        let rules = StubRules()
        rules.blocked = ["app:blocked"]
        let source = StubSource()
        source.stubbedItems = [
            Self.appItem(id: "app:blocked", title: "Safari"),
            Self.appItem(id: "app:plain", title: "Sabre"),
        ]
        let model = makeModel(sources: [source], rules: rules)
        XCTAssertEqual(model.results(for: "sa").map(\.id), ["app:plain"])
    }

    /// Block wins over pin — the states can't coexist through the UI, but
    /// a hand edit can produce both, and "never show" must hold.
    func testBlockBeatsPin() {
        let rules = StubRules()
        rules.pinned = ["app:both"]
        rules.blocked = ["app:both"]
        let source = StubSource()
        source.stubbedItems = [Self.appItem(id: "app:both", title: "Safari")]
        let model = makeModel(sources: [source], rules: rules)
        XCTAssertTrue(model.results(for: "safari").isEmpty)
    }

    /// More matching pins than fit must not swallow the list: the band
    /// caps so the web fallback and a ranked row keep their slots, and
    /// overflowed pins rejoin the pool in rank order.
    func testPinOverflowKeepsWebAndRankedSlots() {
        let rules = StubRules()
        rules.pinned = Set((0..<60).map { "app:safari-\($0)" })
        let apps = StubSource()
        apps.stubbedItems = (0..<60).map { index in
            Self.appItem(id: "app:safari-\(index)", title: "Safari \(index)")
        }
        let model = makeModel(sources: [apps, WebSource()], rules: rules)
        let results = model.results(for: "safari")
        XCTAssertEqual(results.count, SearchModel.maxResults)
        // Band cap = maxResults - web(1) - one reserved ranked slot.
        // (path/calc hits are zero for this query.)
        let bandCap = SearchModel.maxResults - 2
        XCTAssertEqual(results.prefix(bandCap).map(\.id),
                       (0..<bandCap).map { "app:safari-\($0)" })
        XCTAssertEqual(results[bandCap].id, "app:safari-\(bandCap)")
        XCTAssertEqual(results.last?.id, "web:safari")
    }

    /// Blocked functional rows drop too — the filter runs ahead of pin
    /// classification, so a hand-edited `web:`/`calc:` block is honored.
    func testBlockedFunctionalRowDrops() {
        let rules = StubRules()
        rules.blocked = ["web:safari", "calc:2+2"]
        let model = makeModel(sources: [WebSource(), CalculatorSource()],
                              rules: rules)
        XCTAssertTrue(model.results(for: "safari").isEmpty)
        // Only the calc row is blocked on "2+2" — the web fallback for the
        // same query (`web:2+2`) is a different id and still lands.
        XCTAssertEqual(model.results(for: "2+2").map(\.id), ["web:2+2"])
    }

    /// Blocked `path:` rows drop too — the filter runs ahead of the
    /// head-pin classification for the third functional category.
    func testBlockedPathRowDrops() throws {
        let rules = StubRules()
        let pathSource = PathSource()
        // The id carries the standardized path (`/tmp` may canonicalize
        // to `/private/tmp`), so derive it rather than assume the literal.
        let pathID = try XCTUnwrap(
            pathSource.items(matching: "/tmp").first?.id)
        // Baseline first — the row must surface unblocked or the drop
        // assertion below would be vacuous. StubRules is a class, so the
        // block must be set after the baseline model's results are read.
        let clean = makeModel(sources: [pathSource], rules: rules)
        XCTAssertFalse(clean.results(for: "/tmp").isEmpty)
        rules.blocked = [pathID]
        let model = makeModel(sources: [pathSource], rules: rules)
        XCTAssertTrue(model.results(for: "/tmp").isEmpty)
    }
}
