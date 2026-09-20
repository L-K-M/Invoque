import XCTest
@testable import Invoque

final class PanelModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var commandDirectory: URL!
    private var savedFileDebounce: UInt64!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "invoque-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        savedFileDebounce = PanelModel.fileSearchDebounceNanoseconds
        commandDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: commandDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PanelModel.fileSearchDebounceNanoseconds = savedFileDebounce
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

    private static func appItem(id: String, title: String,
                                matchText: String? = nil) -> Item {
        Item(id: id, title: title, subtitle: "", icon: .symbol("app"),
             action: .openApp(URL(fileURLWithPath: "/Applications/\(title).app")),
             matchText: matchText ?? title)
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

    /// `matchText` is search metadata, not display state: a rescan that
    /// changes only it must not count as "changed rows" and reset the
    /// cursor. The `==` on `ResultRow` deliberately excludes it.
    func testRefreshWithMatchTextOnlyChangeKeepsSelection() {
        let source = StubSource(stubbed: [
            Self.appItem(id: "app:one", title: "Alpha",
                         matchText: "Alpha one"),
            Self.appItem(id: "app:two", title: "Amber",
                         matchText: "Amber two"),
        ])
        let model = PanelModel()
        model.searchModel = SearchModel(sources: [source],
                                        frecency: Frecency(defaults: defaults))
        model.query = "a"
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedRow?.id, "app:two")
        source.stubbed = [
            Self.appItem(id: "app:one", title: "Alpha",
                         matchText: "Alpha xxx"),
            Self.appItem(id: "app:two", title: "Amber",
                         matchText: "Amber yyy"),
        ]
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

    // MARK: Permission requests

    private func makePermissionRequest(grants: CommandPermissionGrants,
                                       permissions: [String] = ["shell"],
                                       args: [String] = ["a"]) throws -> CommandPermissionRequest {
        // JSONSerialization, not interpolation — a permission string needing
        // escaping must not corrupt the fixture.
        let payload: [String: Any] = ["schemaVersion": 1, "name": "risky-demo",
                                      "title": "Risky", "runtime": "js",
                                      "entry": "main.js", "mode": "action",
                                      "permissions": permissions]
        let manifest = try JSONDecoder().decode(
            CommandManifest.self,
            from: try JSONSerialization.data(withJSONObject: payload))
        let command = Command(manifest: manifest,
                              directory: URL(fileURLWithPath: "/tmp/risky-demo"))
        // The request comes from the production derivation — if "risky"
        // ever changes, the fixture can't drift into requests the run
        // path would never build.
        return try XCTUnwrap(grants.consentRequest(for: command, args: args),
                             "fixture permissions must include a risky one")
    }

    /// An isolated grants store on a fresh suite, with teardown cleanup
    /// registered — one place so future tests can't leak a persistent domain.
    private func makeFreshGrants() -> CommandPermissionGrants {
        let suiteName = "PanelModelTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create UserDefaults suite \(suiteName)")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return CommandPermissionGrants(defaults: defaults)
    }

    /// Plain ⏎ is neutral while the consent card is up — a permanent grant
    /// must take ⌘⏎ or a click, never a habitual double-⏎.
    func testPlainSubmitIsNeutralOnPendingPermissionRequest() throws {
        let grants = makeFreshGrants()
        let model = makeModel(items: [])
        model.permissionRequest = try makePermissionRequest(grants: grants)

        var confirmed = false
        model.onPermissionConfirmed = { _ in confirmed = true }
        var submitted = false
        model.onSubmit = { _ in submitted = true }
        model.submit()

        XCTAssertFalse(confirmed)
        XCTAssertFalse(submitted, "⏎ must not reach the row underneath the card")
        XCTAssertNotNil(model.permissionRequest)
    }

    /// ⌘⏎ while a consent card is up means Allow — the paused run is handed
    /// back to the controller (which records the grant before resuming).
    func testCommandSubmitConfirmsPendingPermissionRequest() throws {
        let grants = makeFreshGrants()
        let model = makeModel(items: [])
        model.permissionRequest = try makePermissionRequest(grants: grants)

        var confirmed: CommandPermissionRequest?
        model.onPermissionConfirmed = { confirmed = $0 }
        var submitted = false
        model.onSubmit = { _ in submitted = true }
        model.submit(commandModifier: true)

        XCTAssertFalse(submitted)
        XCTAssertEqual(confirmed?.command.name, "risky-demo")
        XCTAssertEqual(confirmed?.args, ["a"])
        XCTAssertNil(model.permissionRequest)
    }

    func testDismissPermissionRequestClearsWithoutGrant() throws {
        let grants = makeFreshGrants()
        let model = makeModel(items: [])
        let request = try makePermissionRequest(grants: grants)
        model.permissionRequest = request

        model.dismissPermissionRequest()
        XCTAssertNil(model.permissionRequest)
        // PanelModel holds no grants store by design — the controller owns
        // grant recording — so "dismiss doesn't grant" is a structural
        // guarantee this assertion pins on the store a grant *would* use.
        XCTAssertEqual(grants.ungranted(for: request.command), [.shell])
    }

    /// A pending consent prompt belongs to the summon that produced it —
    /// the next summon starts clean.
    func testResetClearsPermissionRequest() throws {
        let grants = makeFreshGrants()
        let model = makeModel(items: [])
        model.permissionRequest = try makePermissionRequest(grants: grants)
        model.reset(clearQuery: false)
        XCTAssertNil(model.permissionRequest)
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

    // MARK: File-search mode

    /// Polls `fileRunCompletions` until `atLeast` scans have reached their
    /// completion point — the `awaitCompletions` twin for `find`/`f` runs.
    private func awaitFileCompletions(_ model: PanelModel, atLeast count: Int,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(7)
        while model.fileRunCompletions < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.fileRunCompletions, count,
                                    "file search never completed",
                                    file: file, line: line)
    }

    /// Shrinks the file-search debounce so "past the debounce" sleeps are
    /// short and stay decoupled from the production constant — a debounce
    /// bump can't silently turn a no-scan assertion vacuous. Restored in
    /// tearDown.
    private func withShortFileDebounce() {
        PanelModel.fileSearchDebounceNanoseconds = 10_000_000
    }

    /// The `awaitStarts` twin for file scans.
    private func awaitFileStarts(_ model: PanelModel, atLeast count: Int,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(7)
        while model.fileRunsStarted < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.fileRunsStarted, count,
                                    "file search never started",
                                    file: file, line: line)
    }

    private static func fileItem(_ name: String) -> Item {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return Item(id: Item.fileIDPrefix + url.path, title: name,
                    subtitle: "/tmp", icon: .fileURL(url),
                    action: .openFile(url), matchText: name)
    }

    func testFindKeywordRunsFileSearch() async throws {
        let model = makeModel(items: [])
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find notes"
        await awaitResults(model) { $0.count == 1 }
        XCTAssertEqual(model.results.first?.title, "notes.txt")
        XCTAssertEqual(model.results.first?.action,
                       .openFile(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testFAliasRunsFileSearch() async throws {
        let model = makeModel(items: [])
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "f notes"
        await awaitResults(model) { $0.count == 1 }
        XCTAssertEqual(model.results.first?.title, "notes.txt")
        XCTAssertEqual(model.results.first?.action,
                       .openFile(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testBareFindKeywordStaysNormalSearch() {
        let model = makeModel(items: [Self.appItem(id: "app:finder", title: "Finder")])
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find"
        XCTAssertEqual(model.results.map(\.id), ["app:finder"])
    }

    /// The `f` alias follows the same bare-keyword rule as `find`.
    func testBareFAliasStaysNormalSearch() {
        let model = makeModel(items: [Self.appItem(id: "app:finder", title: "Finder")])
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "f"
        XCTAssertEqual(model.results.map(\.id), ["app:finder"])
    }

    /// Unwired, "find x" is just a query — the same convention as
    /// `filterLookup`/`maker`. The fixture's title must contain the whole
    /// query text for the normal search to surface it.
    func testUnwiredFileSearcherLeavesQueryAsSearch() {
        let model = makeModel(items: [Self.appItem(id: "app:finder",
                                                 title: "Find X Utility")])
        model.query = "find x"
        XCTAssertEqual(model.results.map(\.id), ["app:finder"])
    }

    /// Unwired `f x` degrades to a normal query, mirroring `find x`.
    func testUnwiredFAliasLeavesQueryAsSearch() {
        let model = makeModel(items: [Self.appItem(id: "app:finder",
                                                 title: "F X Utility")])
        model.query = "f x"
        XCTAssertEqual(model.results.map(\.id), ["app:finder"])
    }

    /// A double space after the keyword must not leak whitespace into the
    /// scanned query — `activeFileSearch` trims before the searcher sees it.
    func testFileSearchTrimsExtraSpaces() async throws {
        let model = makeModel(items: [])
        model.fileSearcher = { text, _ in [Self.fileItem("\(text).txt")] }
        model.query = "f  alpha"
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.title), ["alpha.txt"])
    }

    /// A whitespace-plus-newline rest is blank — the model's trim matches
    /// `FileSearch.scan`'s `.whitespacesAndNewlines`, so no doomed scan
    /// is dispatched.
    func testNewlineOnlyFileTextIsBlank() async throws {
        let model = makeModel(items: [])
        withShortFileDebounce()
        model.fileSearcher = { _, _ in [Self.fileItem("x")] }
        model.query = "find \n"
        XCTAssertTrue(model.fileSearchTextIsBlank)
        try await Task.sleep(nanoseconds: 100_000_000) // past the debounce
        XCTAssertEqual(model.fileRunsStarted, 0)
    }

    /// Between scheduling and rows landing the scan is pending — the view
    /// reads this to show progress rather than "No matching files".
    func testFileScanIsPendingDuringScan() async throws {
        let model = makeModel(items: [])
        model.fileSearcher = { _, _ in
            Thread.sleep(forTimeInterval: 0.2)
            return [Self.fileItem("x.txt")]
        }
        model.query = "find x"
        XCTAssertTrue(model.fileScanIsPending) // debouncing already counts
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertFalse(model.fileScanIsPending)
    }

    /// "find " with nothing after it owns an empty list — the mode is
    /// active but no scan runs.
    func testEmptyFileTextOwnsEmptyList() async throws {
        let model = makeModel(items: [Self.appItem(id: "app:finder", title: "Finder")])
        withShortFileDebounce()
        model.fileSearcher = { _, _ in [Self.fileItem("x")] }
        model.query = "finder"
        XCTAssertEqual(model.results.map(\.id), ["app:finder"])
        model.query = "find "
        try await Task.sleep(nanoseconds: 100_000_000) // past the debounce
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.fileRunsStarted, 0)
    }

    /// Backspacing to "find " mid-session must clear the previous scan's
    /// rows — a stale row left on screen is still selectable.
    func testBlankingFileTextClearsRows() async throws {
        let model = makeModel(items: [])
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find a"
        await awaitResults(model) { $0.count == 1 }
        model.query = "find "
        XCTAssertTrue(model.results.isEmpty)
    }

    /// A rescan-driven `refreshResults` on an unchanged `find` session must
    /// not restart a full disk walk for rows already on screen.
    func testIdenticalFileQuerySkipsRescan() async throws {
        let model = makeModel(items: [])
        withShortFileDebounce()
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find a"
        await awaitFileCompletions(model, atLeast: 1)
        model.refreshResults()
        try await Task.sleep(nanoseconds: 100_000_000) // past the debounce
        XCTAssertEqual(model.fileRunsStarted, 1)
        XCTAssertEqual(model.results.map(\.title), ["notes.txt"])
    }

    /// A slow earlier scan must not stamp rows over a newer keystroke's
    /// results — `fileGeneration` drops it.
    func testStaleFileResultIsDropped() async throws {
        let model = makeModel(items: [])
        model.fileSearcher = { text, _ in
            if text == "a" { Thread.sleep(forTimeInterval: 1.0) }
            return [Self.fileItem("\(text).txt")]
        }
        model.query = "find a"
        // The "a" scan must be in flight — not merely scheduled — before
        // the query moves on, or there's nothing stale to drop.
        await awaitFileStarts(model, atLeast: 1)
        model.query = "find ab"
        await awaitFileCompletions(model, atLeast: 2)
        XCTAssertEqual(model.results.map(\.title), ["ab.txt"])
    }

    /// Leaving file mode restores normal results, and the in-flight scan's
    /// late completion is discarded rather than stamped over them.
    func testLeavingFileSearchDropsInFlightResult() async throws {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.fileSearcher = { _, _ in
            Thread.sleep(forTimeInterval: 1.0)
            return [Self.fileItem("stale.txt")]
        }
        model.query = "find a"
        await awaitFileStarts(model, atLeast: 1)
        model.query = "safari"
        XCTAssertEqual(model.results.map(\.id), ["app:safari"])
        // This is the model's first file run, so `atLeast: 1` means "the
        // in-flight scan's landing" — a snapshot baseline could already
        // include it if the scan finished between the start-poll and the
        // capture, and would then wait for a second run that never comes.
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.id), ["app:safari"])
    }

    /// ⌘⏎ on a file row reveals it in Finder rather than opening — the
    /// performer receives a swapped `.revealInFinder` action.
    func testCommandModifierRevealsFileRow() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        let model = makeModel(items: [])
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.showCommandResults([ResultRow(
            id: "file:/tmp/notes.txt", title: "notes.txt", subtitle: "/tmp",
            icon: .fileURL(url), action: .openFile(url))])
        model.submit(commandModifier: true)
        XCTAssertEqual(submitted?.action, .revealInFinder(url))
    }

    /// The same ⌘⏎ reveal applies to app rows.
    func testCommandModifierRevealsAppRow() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.query = "safari"
        model.submit(commandModifier: true)
        XCTAssertEqual(submitted?.action, .revealInFinder(url))
    }

    /// The inverse for a pasted file path: the row's default action is
    /// already reveal, so ⌘⏎ means open.
    func testCommandModifierOpensRevealRow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-\(UUID().uuidString).txt")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel(items: [])
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.showCommandResults([ResultRow(
            id: "path:/tmp/notes.txt", title: "notes.txt", subtitle: "/tmp",
            icon: .fileURL(url), action: .revealInFinder(url))])
        model.submit(commandModifier: true)
        XCTAssertEqual(submitted?.action, .openFile(url))
    }

    /// ⌘⏎ on a pasted `.app` path must stay reveal — opening a package
    /// launches it, and a pasted bundle must not run on either gesture.
    func testCommandModifierKeepsAppPackageOnReveal() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("Invoque-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let url = URL(fileURLWithPath: app.path)
        let model = makeModel(items: [])
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.showCommandResults([ResultRow(
            id: "path:\(app.path)", title: app.lastPathComponent, subtitle: "/tmp",
            icon: .fileURL(url), action: .revealInFinder(url))])
        model.submit(commandModifier: true)
        XCTAssertEqual(submitted?.action, .revealInFinder(url))
    }

    /// A pasted executable keeps the reveal too — a +x file runs under
    /// NSWorkspace.open, so ⌘⏎ must not become the launch gesture.
    func testCommandModifierKeepsExecutableOnReveal() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-\(UUID().uuidString).sh")
        FileManager.default.createFile(atPath: script.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let model = makeModel(items: [])
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.showCommandResults([ResultRow(
            id: "path:\(script.path)", title: script.lastPathComponent,
            subtitle: "/tmp", icon: .fileURL(script),
            action: .revealInFinder(script))])
        model.submit(commandModifier: true)
        XCTAssertEqual(submitted?.action, .revealInFinder(script))
    }

    /// Plain ⏎ still opens — the reveal swap must not leak into it.
    func testPlainReturnOpensFileRow() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        let model = makeModel(items: [])
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.showCommandResults([ResultRow(
            id: "file:/tmp/notes.txt", title: "notes.txt", subtitle: "/tmp",
            icon: .fileURL(url), action: .openFile(url))])
        model.submit()
        XCTAssertEqual(submitted?.action, .openFile(url))
    }

    // MARK: Maker routing

    /// A MakerModel whose LLM is a stub — generation resolves to a clean
    /// draft without touching the network.
    private func makeMaker(responding output: String? = nil) -> MakerModel {
        let client = MakerStubClient()
        client.response = output ?? """
            --- command.json ---
            { "schemaVersion": 1, "name": "gen", "title": "Gen" }
            --- main.js ---
            async function run() { return { title: "done" }; }
            """
        return MakerModel(client: { client },
                          runner: CommandRunner(),
                          writer: CommandWriter(rootURL: commandDirectory),
                          permissionGrants: makeFreshGrants())
    }

    func testMakeKeywordActivatesMaker() {
        let model = makeModel(items: [Self.appItem(id: "app:x", title: "X")])
        model.maker = makeMaker()
        model.query = "make a clipboard formatter"
        XCTAssertEqual(model.makerPrompt, "a clipboard formatter")
        XCTAssertTrue(model.makerIsActive)
        // The maker owns the panel — no search results behind the view.
        XCTAssertTrue(model.results.isEmpty)
    }

    func testMkAliasActivatesMaker() {
        let model = makeModel(items: [])
        model.maker = makeMaker()
        model.query = "mk a thing"
        XCTAssertEqual(model.makerPrompt, "a thing")
        XCTAssertTrue(model.makerIsActive)
    }

    func testBareMakeKeywordStaysSearch() {
        let model = makeModel(items: [Self.appItem(id: "app:maker", title: "Maker")])
        model.maker = makeMaker()
        model.query = "make"
        XCTAssertNil(model.makerPrompt)
        XCTAssertFalse(model.makerIsActive)
        XCTAssertEqual(model.results.map(\.id), ["app:maker"])
    }

    func testUnwiredMakerLeavesQueryAsSearch() {
        // No maker injected — `make x` behaves like an ordinary query.
        let model = makeModel(items: [Self.appItem(id: "app:x", title: "X")])
        model.query = "make x"
        XCTAssertFalse(model.makerIsActive)
    }

    func testSubmitWhileMakerActiveStartsGeneration() async {
        let model = makeModel(items: [])
        let maker = makeMaker()
        model.maker = maker
        model.query = "make something"
        var submitted = false
        model.onSubmit = { _ in submitted = true }
        model.submit()

        // The maker got the prompt instead of a row submission.
        XCTAssertFalse(submitted)
        for _ in 0..<100 {
            if await maker.phase == .readyToSave { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let phase = await maker.phase
        XCTAssertEqual(phase, .readyToSave)
        // Even after the async generation settled, onSubmit must never
        // have fired — the maker owns the submit while it's active.
        XCTAssertFalse(submitted, "submit must route to the maker, not onSubmit")
    }

    func testBackspacingPromptExitsMakerAndRestoresSearch() {
        // Editing back to a bare `make` hands the panel back to search.
        let model = makeModel(items: [Self.appItem(id: "app:maker", title: "Maker")])
        model.maker = makeMaker()
        model.query = "make thing"
        XCTAssertTrue(model.makerIsActive)
        model.query = "make"
        XCTAssertFalse(model.makerIsActive)
        XCTAssertEqual(model.results.map(\.id), ["app:maker"])
    }

    func testGarbageLLMOutputNeverBecomesSavable() async {
        // The unhappy path: output with no manifest/entry blocks must not
        // reach a phase where Save is enabled.
        let model = makeModel(items: [])
        let maker = makeMaker(responding: "sorry, I cannot generate that")
        model.maker = maker
        model.query = "make something"
        model.submit()
        for _ in 0..<100 {
            let phase = await maker.phase
            if phase == .failed || phase == .draft { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let phase = await maker.phase
        // The stub returned unparseable prose — the exact terminal state
        // is .failed, which the negative assertions alone can't pin down
        // (a broken routing would leave .idle and still "pass").
        XCTAssertEqual(phase, .failed)
    }

    // MARK: Result stability

    /// Typing more letters must not reorder rows that still match.
    /// "Safxa" prefix-matches "saf" but only *fuzzy*-matches "safa" — a
    /// plain re-sort would demote it below the still-prefix "SafariLong";
    /// stability keeps the displayed order.
    func testExtendingQueryKeepsStillMatchingRowsInPlace() {
        let model = makeModel(items: [
            Self.appItem(id: "app:degrades", title: "Safxa"),
            Self.appItem(id: "app:stable", title: "SafariLong"),
        ])
        model.query = "saf"
        // Both prefix-hit; the shorter match text leads.
        XCTAssertEqual(model.results.map(\.id), ["app:degrades", "app:stable"])
        model.query = "safa"
        // A fresh rank would order [stable, degrades] — prefix beats
        // fuzzy — but the survivor keeps its slot.
        XCTAssertEqual(model.results.map(\.id), ["app:degrades", "app:stable"])
    }

    /// Non-extension edits re-rank fresh — deletion gets the shorter
    /// query's natural order, not the extended query's leftovers.
    func testShrinkingQueryReranks() {
        let model = makeModel(items: [
            Self.appItem(id: "app:degrades", title: "Safxa"),
            Self.appItem(id: "app:stable", title: "SafariLong"),
        ])
        model.query = "safa"
        XCTAssertEqual(model.results.map(\.id), ["app:stable", "app:degrades"])
        model.query = "saf"
        XCTAssertEqual(model.results.map(\.id), ["app:degrades", "app:stable"])
    }

    /// Rows that stop matching drop out on extension — stability protects
    /// positions, not stale rows.
    func testExtensionDropsNonMatchingRows() {
        let model = makeModel(items: [
            Self.appItem(id: "app:keeper", title: "Safari"),
            Self.appItem(id: "app:gone", title: "SafZ"),
        ])
        model.query = "saf"
        XCTAssertEqual(model.results.map(\.id), ["app:gone", "app:keeper"])
        model.query = "safa"
        // "SafZ" has no second 'a' — it's gone, not merely reordered.
        XCTAssertEqual(model.results.map(\.id), ["app:keeper"])
    }

    /// An extended query keeps the calculator's top slot — a still-matching
    /// survivor must not float above the fresh pinned answer.
    func testExtensionKeepsCalculatorPinOnTop() {
        let model = PanelModel()
        model.searchModel = SearchModel(
            sources: [StubSource(stubbed: [
                Self.appItem(id: "app:calc-tool", title: "1+1*2 Helper"),
            ]), CalculatorSource()],
            frecency: Frecency(defaults: defaults))
        model.query = "1+1"
        XCTAssertTrue(model.results.first?.id.hasPrefix("calc:") ?? false)
        model.query = "1+1*2"
        XCTAssertTrue(model.results.first?.id.hasPrefix("calc:") ?? false)
        XCTAssertTrue(model.results.contains { $0.id == "app:calc-tool" })
    }

    /// The cap applies to the ranked middle only: a page of survivors
    /// must not slice the pinned web row off the bottom of the merged
    /// list — calculator stays first, web stays last.
    func testPinnedRowsSurviveExtensionAtCap() {
        var items = (0..<60).map {
            Self.appItem(id: "app:\($0)", title: "AB\($0)")
        }
        items.append(Item(id: Item.calculatorIDPrefix + "sum", title: "42",
                          subtitle: "", icon: .symbol("plus"),
                          action: .copyText("42"), matchText: "42"))
        items.append(Item(id: Item.webIDPrefix + "q",
                          title: "Search the web", subtitle: "",
                          icon: .symbol("globe"),
                          action: .openURL(URL(
                            string: "https://example.com")!),
                          matchText: "Search the web"))
        let model = makeModel(items: items)
        model.query = "a"
        XCTAssertEqual(model.results.count, SearchModel.maxResults)
        // "ab" extends "a" and still prefix-matches every "ABn" — all 48
        // displayed rows survive, so the merge is at capacity.
        model.query = "ab"
        XCTAssertEqual(model.results.count, SearchModel.maxResults)
        XCTAssertEqual(model.results.first?.id,
                       Item.calculatorIDPrefix + "sum")
        XCTAssertEqual(model.results.last?.id, Item.webIDPrefix + "q")
    }

    /// File scans get the same stability: rows that still match the grown
    /// text keep their positions even when the fresh scan re-ranks them.
    func testFileResultsStabilizeOnExtension() async throws {
        let model = makeModel(items: [])
        withShortFileDebounce()
        model.fileSearcher = { text, _ in
            // The stub re-ranks per query — "safa" puts the longer,
            // still-prefix file first and demotes the fuzzy survivor.
            if text == "saf" {
                return [Self.fileItem("safxa.txt"), Self.fileItem("safarilong.txt")]
            }
            return [Self.fileItem("safarilong.txt"), Self.fileItem("safxa.txt")]
        }
        model.query = "find saf"
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.title), ["safxa.txt", "safarilong.txt"])
        model.query = "find safa"
        await awaitFileCompletions(model, atLeast: 2)
        // "safxa.txt" still fuzzy-matches "safa" — it keeps its slot.
        XCTAssertEqual(model.results.map(\.title), ["safxa.txt", "safarilong.txt"])
    }

    /// A row that first appears on the extended completion — a streamed
    /// hit or a refreshed source — joins at its fresh rank *below* the
    /// survivors, even when the fresh pass outranks them.
    func testFileNewcomerJoinsBelowSurvivors() async throws {
        let model = makeModel(items: [])
        withShortFileDebounce()
        model.fileSearcher = { text, _ in
            if text == "saf" { return [Self.fileItem("safxa.txt")] }
            return [Self.fileItem("safarilong.txt"), Self.fileItem("safxa.txt")]
        }
        model.query = "find saf"
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.title), ["safxa.txt"])
        model.query = "find safa"
        await awaitFileCompletions(model, atLeast: 2)
        // "safarilong.txt" wins the fresh pass on tier but is a newcomer —
        // it lands below the survivor rather than displacing it.
        XCTAssertEqual(model.results.map(\.title),
                       ["safxa.txt", "safarilong.txt"])
    }

    /// A mode change can't leak the last search's stability anchor — rows
    /// from a file session must not head a later normal search's list.
    func testFileToSearchTransitionReranks() async throws {
        let model = makeModel(items: [
            Self.appItem(id: "app:notes-app", title: "Notes"),
            Self.appItem(id: "app:nope", title: "Nope"),
        ])
        withShortFileDebounce()
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find notes"
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.title), ["notes.txt"])
        // "notes" is not an extension of the file text session — a normal
        // search ranks fresh.
        model.query = "notes"
        XCTAssertEqual(model.results.map(\.id), ["app:notes-app"])
    }

    // MARK: Pin & block

    /// A mutable pin/block backing standing in for the `Preferences`
    /// closures — the toggles write into plain sets the test can inspect,
    /// and fire `changed` the way `Preferences.entryRulesChanged` does:
    /// the notification, not the toggle, is what re-lists the panel.
    private final class RulesStub {
        var pinned = Set<String>()
        var blocked = Set<String>()
        var changed: (() -> Void)?
        var entryRules: EntryRules {
            EntryRules(
                isPinned: { [self] in pinned.contains($0) },
                isBlocked: { [self] in blocked.contains($0) },
                togglePin: { [self] id, _ in
                    defer { changed?() }
                    if pinned.contains(id) { pinned.remove(id); return false }
                    pinned.insert(id)
                    return true
                },
                toggleBlock: { [self] id, _ in
                    defer { changed?() }
                    if blocked.contains(id) { blocked.remove(id); return false }
                    pinned.remove(id)
                    blocked.insert(id)
                    return true
                })
        }
    }

    /// A model whose panel and search layers share one rules facade —
    /// the production wiring, minus Preferences: toggles notify through
    /// `changed`, exactly like `entryRulesChanged` → `entryRulesDidChange`.
    private func makeManagedModel(items: [Item], rules: RulesStub) -> PanelModel {
        let model = PanelModel()
        model.searchModel = SearchModel(
            sources: [StubSource(stubbed: items)],
            frecency: Frecency(defaults: defaults),
            entryRules: rules.entryRules)
        model.entryRules = rules.entryRules
        rules.changed = { [weak model] in model?.entryRulesDidChange() }
        return model
    }

    /// Pinning the selection boosts it above a strictly better match and
    /// reports the change as HUD text.
    func testTogglePinBoostsSelection() {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:winner", title: "Safari"),
            Self.appItem(id: "app:loser", title: "SanFran"),
        ], rules: rules)
        model.query = "saf"
        XCTAssertEqual(model.results.map(\.id), ["app:winner", "app:loser"])
        model.moveSelection(by: 1)
        XCTAssertEqual(model.togglePin(), "Pinned SanFran")
        XCTAssertTrue(rules.pinned.contains("app:loser"))
        XCTAssertEqual(model.results.map(\.id), ["app:loser", "app:winner"])
        XCTAssertTrue(model.isPinned(model.results[0]))
    }

    /// A second toggle reverses the first — and the row drops back to
    /// its ranked slot on the same refresh.
    func testTogglePinTwiceUnpins() {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:winner", title: "Safari"),
            Self.appItem(id: "app:loser", title: "SanFran"),
        ], rules: rules)
        model.query = "saf"
        model.togglePin(on: model.results[1])
        XCTAssertEqual(model.togglePin(on: model.results[0]), "Unpinned SanFran")
        XCTAssertTrue(rules.pinned.isEmpty)
        XCTAssertEqual(model.results.map(\.id), ["app:winner", "app:loser"])
    }

    /// Blocking the selection removes the row on the spot and reports it.
    func testToggleBlockRemovesRow() {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:winner", title: "Safari"),
            Self.appItem(id: "app:loser", title: "SanFran"),
        ], rules: rules)
        model.query = "saf"
        XCTAssertEqual(model.toggleBlock(on: model.results[0]),
                       "Blocked Safari")
        XCTAssertTrue(rules.blocked.contains("app:winner"))
        XCTAssertEqual(model.results.map(\.id), ["app:loser"])
    }

    /// Functional rows (`web:`/`calc:`/`path:`) and ephemeral `filter:`
    /// rows aren't entries — no affordance, no toggle.
    func testToggleOnNonManageableRowIsNil() throws {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:safari", title: "Safari"),
            Item(id: "web:saf", title: "Search the web", subtitle: "",
                 icon: .symbol("globe"),
                 action: .openURL(URL(string: "https://example.com")!),
                 matchText: "web"),
        ], rules: rules)
        model.query = "saf"
        let web = try XCTUnwrap(model.results.last)
        XCTAssertEqual(web.id, "web:saf")
        XCTAssertFalse(model.canManage(web))
        XCTAssertNil(model.togglePin(on: web))
        XCTAssertNil(model.toggleBlock(on: web))
        XCTAssertTrue(model.canManage(model.results[0]))
    }

    /// No selection — empty results — means the chords no-op silently.
    func testToggleWithNoSelectionIsNil() {
        let rules = RulesStub()
        let model = makeManagedModel(items: [], rules: rules)
        XCTAssertNil(model.togglePin())
        XCTAssertNil(model.toggleBlock())
    }

    /// The consent card owns the panel: pin/block chords can't act on
    /// the list sitting underneath it.
    func testToggleDuringPermissionRequestIsNil() throws {
        let grants = makeFreshGrants()
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:safari", title: "Safari"),
        ], rules: rules)
        model.query = "safari"
        model.permissionRequest = try makePermissionRequest(grants: grants)
        XCTAssertNil(model.togglePin())
        XCTAssertNil(model.toggleBlock())
        XCTAssertTrue(rules.pinned.isEmpty)
        XCTAssertTrue(rules.blocked.isEmpty)
    }

    /// Block beats pin through the wired path — the stub allows the
    /// overlap a hand-edited defaults file could hold, and "never show"
    /// must win at the panel, not just inside `SearchModel`.
    func testBlockBeatsPin() {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:notes", title: "Notes"),
        ], rules: rules)
        rules.pinned = ["app:notes"]
        rules.blocked = ["app:notes"]
        model.query = "not"
        XCTAssertTrue(model.results.isEmpty)
    }

    /// Extending the query keeps displayed order inside the pin band too:
    /// "safi" re-tiers "Safxafi" from prefix to fuzzy — a fresh rank would
    /// swap the two pins — but the survivor merge holds their slots.
    func testPinnedSurvivorsKeepOrderOnExtension() {
        let rules = RulesStub()
        rules.pinned = ["app:long", "app:short"]
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:long", title: "Safari Tool"),
            Self.appItem(id: "app:short", title: "Safxafi"),
        ], rules: rules)
        model.query = "saf"
        // Both pinned: "Safxafi" (7-char prefix) outranks "Safari Tool"
        // (11-char prefix) — band order [short, long].
        XCTAssertEqual(model.results.map(\.id), ["app:short", "app:long"])
        model.query = "safi"
        // Fresh rank would now put the still-prefix "Safari Tool" over
        // the now-fuzzy "Safxafi" — stability must hold the swap back.
        XCTAssertEqual(model.results.map(\.id), ["app:short", "app:long"])
    }

    /// The Settings-list path: an outside change plus `entryRulesDidChange`
    /// (what `Preferences.entryRulesChanged` fires) re-lists the open query.
    func testExternalBlockRefreshesOpenResults() {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:winner", title: "Safari"),
            Self.appItem(id: "app:loser", title: "SanFran"),
        ], rules: rules)
        model.query = "saf"
        rules.blocked = ["app:winner"]
        model.entryRulesDidChange()
        XCTAssertEqual(model.results.map(\.id), ["app:loser"])
    }

    /// File mode: a blocked scan hit vanishes from the displayed list
    /// without a second disk walk — the cached raw rows reshape.
    func testFileModeBlockRemovesRowWithoutRescan() async throws {
        let rules = RulesStub()
        let model = makeManagedModel(items: [], rules: rules)
        withShortFileDebounce()
        model.fileSearcher = { _, _ in
            [Self.fileItem("keep.txt"), Self.fileItem("drop.txt")]
        }
        model.query = "find txt"
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.title), ["keep.txt", "drop.txt"])
        let starts = model.fileRunsStarted

        let dropped = model.results[1]
        XCTAssertEqual(model.toggleBlock(on: dropped), "Blocked drop.txt")
        XCTAssertEqual(model.results.map(\.title), ["keep.txt"])
        // The rescan-free reshape: no new scan ran for the same session.
        XCTAssertEqual(model.fileRunsStarted, starts)
    }

    /// Pinning a file row moves it to the top of the scan list — the
    /// file-mode twin of the ranked pin band.
    func testFileModePinLeads() async throws {
        let rules = RulesStub()
        let model = makeManagedModel(items: [], rules: rules)
        withShortFileDebounce()
        model.fileSearcher = { _, _ in
            [Self.fileItem("alpha.txt"), Self.fileItem("beta.txt")]
        }
        model.query = "find txt"
        await awaitFileCompletions(model, atLeast: 1)
        XCTAssertEqual(model.results.map(\.title), ["alpha.txt", "beta.txt"])

        XCTAssertEqual(model.togglePin(on: model.results[1]), "Pinned beta.txt")
        XCTAssertEqual(model.results.map(\.title), ["beta.txt", "alpha.txt"])
        XCTAssertTrue(model.isPinned(model.results[0]))
    }

    /// A rules change while a file session is open reshapes the cached
    /// rows — the same-session rescan `scheduleFileSearch` refuses is
    /// exactly what this path covers.
    func testFileModeExternalRulesChangeReshapes() async throws {
        let rules = RulesStub()
        let model = makeManagedModel(items: [], rules: rules)
        withShortFileDebounce()
        model.fileSearcher = { _, _ in
            [Self.fileItem("alpha.txt"), Self.fileItem("beta.txt")]
        }
        model.query = "find txt"
        await awaitFileCompletions(model, atLeast: 1)
        let starts = model.fileRunsStarted

        rules.blocked = ["file:/tmp/alpha.txt"]
        model.entryRulesDidChange()
        XCTAssertEqual(model.results.map(\.title), ["beta.txt"])
        XCTAssertEqual(model.fileRunsStarted, starts)
    }

    /// Leaving file mode drops the cached raw rows with the session —
    /// a stale cache must not bleed into the next `find`.
    func testFileModeExitClearsShapedState() async throws {
        let rules = RulesStub()
        let model = makeManagedModel(items: [
            Self.appItem(id: "app:notes", title: "Notes"),
        ], rules: rules)
        withShortFileDebounce()
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find notes"
        await awaitFileCompletions(model, atLeast: 1)
        model.query = "notes"
        XCTAssertEqual(model.results.map(\.id), ["app:notes"])
    }

    // MARK: Helpers

    private final class MakerStubClient: LLMClientServing {
        var model = "stub"
        var response = ""
        func complete(messages: [LLMMessage]) async throws -> String { response }
    }

    private final class StubSource: ItemSource {
        var stubbed: [Item]
        init(stubbed: [Item]) { self.stubbed = stubbed }
        func items(matching query: String) -> [Item] { stubbed }
    }
}
