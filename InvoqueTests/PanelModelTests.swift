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
    private func writeFilterCommand(keyword: String, source: String,
                                    name: String = "test-filter") throws -> Command {
        let manifest = """
        {
          "schemaVersion": 1, "name": "\(name)", "title": "\(name)",
          "runtime": "js", "entry": "main.js", "mode": "filter",
          "keywords": ["\(keyword)"]
        }
        """
        try manifest.write(to: commandDirectory.appendingPathComponent("command.json"),
                           atomically: true, encoding: .utf8)
        try source.write(to: commandDirectory.appendingPathComponent("main.js"),
                         atomically: true, encoding: .utf8)
        return try Command(directory: commandDirectory)
    }

    /// Polls until `model.results` satisfies `predicate` or ~2 s pass —
    /// filter results arrive asynchronously past the 80 ms debounce.
    private func awaitResults(_ model: PanelModel,
                              _ predicate: ([ResultRow]) -> Bool) async {
        for _ in 0..<100 where !predicate(model.results) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testEnterFilterActionExpandsQuery() throws {
        let item = Item(id: "cmd:json", title: "JSON Tools", subtitle: "",
                        icon: .symbol("terminal"), action: .enterFilter(keyword: "jf"),
                        matchText: "JSON Tools")
        let model = makeModel(items: [item])
        model.query = "json"
        model.submit()
        XCTAssertEqual(model.query, "jf ")
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
        let command = try writeFilterCommand(keyword: "jf", source: """
            async function run(args) {
                return { items: [{ title: "got " + args[0] }] };
            }
            """)
        let model = makeModel(items: [])
        model.filterLookup = { $0 == "jf" ? command : nil }
        model.commandRunner = CommandRunner()
        // Two keystroke states land inside one debounce window; the first
        // task is cancelled before it can run.
        model.query = "jf a"
        model.query = "jf ab"

        await awaitResults(model) { $0.count == 1 }
        XCTAssertEqual(model.results.map(\.title), ["got ab"])
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
