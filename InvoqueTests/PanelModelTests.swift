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
        model.fileSearcher = { _, _ in [Self.fileItem("x")] }
        model.query = "finder"
        XCTAssertEqual(model.results.map(\.id), ["app:finder"])
        model.query = "find "
        try await Task.sleep(nanoseconds: 300_000_000) // past the debounce
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
        model.fileSearcher = { _, _ in [Self.fileItem("notes.txt")] }
        model.query = "find a"
        await awaitFileCompletions(model, atLeast: 1)
        model.refreshResults()
        try await Task.sleep(nanoseconds: 300_000_000) // past the debounce
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
