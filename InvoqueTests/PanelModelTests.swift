import XCTest
@testable import Invoque

final class PanelModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var commandDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "invoque-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        commandDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: commandDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: commandDirectory)
        commandDirectory = nil
        try super.tearDownWithError()
    }

    private func makeModel(items: [Item]) -> PanelModel {
        let model = PanelModel()
        model.searchModel = SearchModel(
            sources: [StubSource(stubbed: items)],
            frecency: Frecency(defaults: defaults))
        return model
    }

    private static func appItem(id: String, title: String) -> Item {
        Item(id: id, title: title, subtitle: "", icon: .symbol("app"),
             action: .openApp(URL(fileURLWithPath: "/Applications/\(title).app")),
             matchText: title)
    }

    // MARK: Query → results

    func testQueryChangePopulatesResults() {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.query = "safari"
        XCTAssertEqual(model.results.map(\.title), ["Safari"])
    }

    func testEmptyQueryYieldsNoResults() {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.query = "safari"
        XCTAssertFalse(model.results.isEmpty)
        model.query = ""
        XCTAssertTrue(model.results.isEmpty)
    }

    func testNewResultSetResetsSelectionToTop() {
        let model = makeModel(items: [
            Self.appItem(id: "app:one", title: "Alpha"),
            Self.appItem(id: "app:two", title: "Amber"),
        ])
        model.query = "a"
        // Same length, same match — the tie breaks by title: Alpha first.
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedRow?.id, "app:two")

        // A new query replaces the list — the index must not carry over
        // onto an unrelated row. "alph" still matches one app (Alpha), so
        // the reset is exercised against a non-empty result set.
        model.query = "alph"
        XCTAssertEqual(model.results.map(\.id), ["app:one"])
        XCTAssertEqual(model.selection, 0)
    }

    func testRefreshResultsRerunsOpenQuery() {
        let source = StubSource(stubbed: [Self.appItem(id: "app:safari", title: "Safari")])
        let model = PanelModel()
        model.searchModel = SearchModel(sources: [source],
                                        frecency: Frecency(defaults: defaults))
        model.query = "safari"
        source.stubbed = []
        // AppSource.onReload lands here: a scan finishing after the panel
        // opened must refill the visible list without a keystroke.
        model.refreshResults()
        XCTAssertTrue(model.results.isEmpty)
    }

    func testRefreshResultsWithUnchangedDataKeepsSelection() {
        // A background rescan returning identical rows must not reset the
        // selection the user already moved off the top row.
        let source = StubSource(stubbed: [
            Self.appItem(id: "app:one", title: "Alpha"),
            Self.appItem(id: "app:two", title: "Amber"),
        ])
        let model = PanelModel()
        model.searchModel = SearchModel(sources: [source],
                                        frecency: Frecency(defaults: defaults))
        model.query = "a"
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedRow?.id, "app:two")
        model.refreshResults()
        XCTAssertEqual(model.selectedRow?.id, "app:two")
    }

    // MARK: Submit

    func testSubmitHandsSelectedRowToCallback() {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.query = "safari"
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.submit()
        XCTAssertEqual(submitted?.id, "app:safari")
        guard case .openApp? = submitted?.action else {
            return XCTFail("expected openApp action, got \(String(describing: submitted?.action))")
        }
    }

    func testSubmitWithNoResultsPassesNil() {
        let model = makeModel(items: [])
        model.query = "nothing matches"
        var called = false
        model.onSubmit = { called = true; XCTAssertNil($0) }
        model.submit()
        XCTAssertTrue(called)
    }

    // MARK: Filter mode

    /// A real filter-mode command on disk — `CommandRunner` runs the file.
    /// Each command gets its own subdirectory so multiple commands coexist.
    private func writeFilterCommand(keyword: String, source: String,
                                    name: String = "test-filter") throws -> Command {
        let directory = commandDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "schemaVersion": 1, "name": name, "title": name,
            "runtime": "js", "entry": "main.js", "mode": "filter",
            "keywords": [keyword],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: directory.appendingPathComponent("command.json"),
                       options: .atomic)
        try source.write(to: directory.appendingPathComponent("main.js"),
                         atomically: true, encoding: .utf8)
        return try Command(directory: directory)
    }

    /// Polls until `model.results` satisfies `predicate` or ~2 s pass —
    /// filter results arrive asynchronously past the 80 ms debounce.
    /// Times out with a real failure rather than a downstream mismatch.
    private func awaitResults(_ model: PanelModel,
                              _ predicate: ([ResultRow]) -> Bool,
                              file: StaticString = #filePath,
                              line: UInt = #line) async {
        for _ in 0..<100 where !predicate(model.results) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate(model.results),
                      "Timed out waiting for results", file: file, line: line)
    }

    /// Polls `filterRunCompletions` until `atLeast` filter runs have reached
    /// their completion point — the deterministic way to await debounced
    /// runs whose rows may be dropped (stale) or deduplicated (identical).
    private func awaitCompletions(_ model: PanelModel, atLeast count: Int,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(7)
        while model.filterRunCompletions < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.filterRunCompletions, count,
                                    "filter run never completed",
                                    file: file, line: line)
    }

    /// Polls `filterRunsStarted` until `atLeast` debounced runs have been
    /// submitted to the runner — i.e. the run is genuinely in flight, not
    /// merely scheduled behind the debounce timer.
    private func awaitStarts(_ model: PanelModel, atLeast count: Int,
                             file: StaticString = #filePath,
                             line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(7)
        while model.filterRunsStarted < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.filterRunsStarted, count,
                                    "filter run never started",
                                    file: file, line: line)
    }

    func testEnterFilterActionExpandsQuery() throws {
        let item = Item(id: "cmd:json", title: "JSON Tools", subtitle: "",
                        icon: .symbol("terminal"),
                        action: .enterFilter(keyword: "jf", commandName: "json"),
                        matchText: "JSON Tools")
        let model = makeModel(items: [item])
        model.query = "json"
        model.submit()
        XCTAssertEqual(model.query, "jf ")
    }

    func testEnterFilterPinsPickedCommandPastKeywordCollision() async throws {
        // Two filter commands claim the same trigger "jf". Picking B's row
        // must run B — the pin routes by identity, not by first match.
        let commandA = try writeFilterCommand(keyword: "jf",
            source: "async function run() { return { items: [{ title: 'from A' }] }; }",
            name: "a-filter")
        let commandB = try writeFilterCommand(keyword: "jf",
            source: "async function run() { return { items: [{ title: 'from B' }] }; }",
            name: "b-filter")
        let rowB = ResultRow(id: "cmd:b-filter", title: "B", subtitle: "",
                             icon: .symbol("terminal"),
                             action: .enterFilter(keyword: "jf", commandName: "b-filter"))
        let model = makeModel(items: [])
        // Plain keyword routing resolves to A — the collision loser.
        model.filterLookup = { $0 == "jf" ? commandA : nil }
        model.commandLookup = { $0 == "b-filter" ? commandB : nil }
        model.commandRunner = CommandRunner()

        model.query = "jf q"
        await awaitResults(model) { $0.count == 1 }
        XCTAssertEqual(model.results.map(\.title), ["from A"])

        // Picking B's row pins the session — same expanded query, but the
        // pin routes it to B instead of the collision's first-match A.
        model.showCommandResults([rowB])
        model.submit()

        XCTAssertEqual(model.query, "jf ")
        await awaitResults(model) { $0.map(\.title) == ["from B"] }
    }

    func testFilterKeywordRunsCommandAndMapsRows() async throws {
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run(args) {
                return { items: [
                    { title: "got " + args[0], arg: "https://example.com/" + args[0] },
                    { title: "copy " + args[0], arg: "text:" + args[0] },
                ] };
            }
            """)
        let model = makeModel(items: [])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf abc"

        await awaitResults(model) { $0.count == 2 }
        XCTAssertEqual(model.results.map(\.title), ["got abc", "copy abc"])
        XCTAssertEqual(model.results.first?.id, "filter:test-filter:0")
        // An http(s) arg opens; anything else copies.
        XCTAssertEqual(model.results[0].action,
                       .openURL(URL(string: "https://example.com/abc")!))
        XCTAssertEqual(model.results[1].action, .copyText("text:abc"))
    }

    func testBareKeywordDoesNotEnterFilterMode() async throws {
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run() { return { items: [{ title: "x" }] }; }
            """)
        let model = makeModel(items: [Self.appItem(id: "app:jfutil", title: "JF Utility")])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf"
        // No trailing space → normal search, not the filter list.
        XCTAssertEqual(model.results.map(\.id), ["app:jfutil"])
    }

    func testStaleFilterResultIsDropped() async throws {
        // The "a" run must actually start (past the debounce) and be slow,
        // so its completion arrives after the "ab" run's. Without the
        // generation guard, the stale "got a" would overwrite the list.
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run(args) {
                if (args[0] === "a") {
                    const t = Date.now();
                    while (Date.now() - t < 300) {}
                }
                return { items: [{ title: "got " + args[0] }] };
            }
            """)
        let model = makeModel(items: [])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf a"
        // Wait until the debounced "a" run is actually in flight — a fixed
        // sleep can lose to a delayed debounce, leaving only one run and a
        // completion target of two that never arrives.
        await awaitStarts(model, atLeast: 1)
        model.query = "jf ab"

        // Both completions must land — the stale "a" is dropped by the
        // generation guard, the fresh "ab" populates the list.
        await awaitCompletions(model, atLeast: 2)
        XCTAssertEqual(model.results.map(\.title), ["got ab"])
    }

    func testIdenticalFilterRowsKeepSelection() async throws {
        // A re-run returning identical rows must not reset the selection —
        // same guard the synchronous search path applies to rescans.
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run() {
                return { items: [{ title: "one" }, { title: "two" }] };
            }
            """)
        let model = makeModel(items: [])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf x"
        await awaitResults(model) { $0.count == 2 }

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 1)
        // A rescan firing while a filter session is active re-runs the
        // command — identical output must not yank the selection. The
        // count predicate is already satisfied by the first run's rows,
        // so wait on the completion counter instead.
        model.refreshResults()
        await awaitCompletions(model, atLeast: 2)
        XCTAssertEqual(model.selection, 1)
    }

    func testFilterRowWithoutArgCopiesTitle() async throws {
        // PLAN §4.1: a row with nothing to do still does something harmless.
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run() { return { items: [{ title: "bare" }] }; }
            """)
        let model = makeModel(items: [])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf x"
        await awaitResults(model) { $0.count == 1 }
        XCTAssertEqual(model.results.first?.action, .copyText("bare"))
    }

    func testLeavingFilterModeDropsInFlightResult() async throws {
        // Exit filter mode while the slow run is in flight — its late
        // completion must not overwrite the restored search results.
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run(args) {
                const t = Date.now();
                while (Date.now() - t < 300) {}
                return { items: [{ title: "stale" }] };
            }
            """)
        let model = makeModel(items: [Self.appItem(id: "app:jf", title: "JF App")])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf a"
        // The run must be in flight — not merely scheduled — before the
        // exit, or the stale landing this test waits for never happens.
        await awaitStarts(model, atLeast: 1)

        // Snapshot before exiting filter mode — the in-flight run can land
        // at any point after the query change, which would inflate the
        // baseline read below and make the target unreachable.
        let completionsBeforeExit = model.filterRunCompletions
        model.query = "jf" // back to bare keyword → normal search
        XCTAssertEqual(model.results.map(\.id), ["app:jf"])
        // The counter is cumulative — wait for one *new* completion: the
        // in-flight run's landing, which the generation bump must drop.
        await awaitCompletions(model, atLeast: completionsBeforeExit + 1)
        XCTAssertEqual(model.results.map(\.id), ["app:jf"])
    }

    func testFilterFailureShowsErrorRow() async throws {
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run() { throw new Error("nope"); }
            """)
        let model = makeModel(items: [])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        model.query = "jf x"

        await awaitResults(model) { !$0.isEmpty }
        XCTAssertEqual(model.results.first?.title, "Command failed")
        XCTAssertEqual(model.results.first?.subtitle, "nope")
    }

    // MARK: Helpers

    private final class StubSource: ItemSource {
        var stubbed: [Item]
        init(stubbed: [Item]) { self.stubbed = stubbed }
        func items(matching query: String) -> [Item] { stubbed }
    }
}
