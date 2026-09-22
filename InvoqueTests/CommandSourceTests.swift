import XCTest
@testable import Invoque

final class CommandSourceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-cmdsrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testCommandsSurfaceAsItems() throws {
        try writeCommand("fmt-json", title: "Format JSON",
                         keywords: ["json", "pretty"])
        let source = CommandSource(store: store(), autoReload: false)
        let items = source.items(matching: "json")

        XCTAssertEqual(items.map(\.id), ["cmd:fmt-json"])
        XCTAssertEqual(items.first?.title, "Format JSON")
        XCTAssertEqual(items.first?.action, .runCommand("fmt-json", []))
        // Keywords are invisible match words — "pretty" must find it.
        XCTAssertTrue(items.first?.matchText.contains("pretty") ?? false)
        // Matching itself is SearchModel's job against matchText — covered
        // by the assertion above; `items(matching:)` is unfiltered by design.
    }

    func testFilterCommandItemEntersFilterMode() throws {
        try writeCommand("emoji", title: "Emoji Picker", mode: "filter",
                         keywords: ["em"])
        let source = CommandSource(store: store(), autoReload: false)
        let item = source.items(matching: "").first

        XCTAssertEqual(item?.action, .enterFilter(keyword: "em", commandName: "emoji"))
        XCTAssertEqual(source.filterCommand(forKeyword: "em")?.manifest.name, "emoji")
        XCTAssertNil(source.filterCommand(forKeyword: "nope"))
    }

    func testOnlyFirstKeywordTriggersFilterMode() throws {
        // PLAN §3: the first keywords entry is the trigger word — later
        // entries are search words only.
        try writeCommand("emoji-picker", title: "Emoji Picker", mode: "filter",
                         keywords: ["em", "emoji"])
        let source = CommandSource(store: store(), autoReload: false)
        XCTAssertEqual(source.filterCommand(forKeyword: "em")?.manifest.name,
                       "emoji-picker")
        XCTAssertNil(source.filterCommand(forKeyword: "emoji"))
    }

    func testNameMatchWinsOverKeywordCollision() throws {
        // Command A is *named* "go"; command B only claims "go" as a
        // keyword. The name is the stronger identity — it wins.
        try writeCommand("go", title: "Go", mode: "filter", keywords: [])
        try writeCommand("b-cmd", title: "B", mode: "filter", keywords: ["go"])
        let source = CommandSource(store: store(), autoReload: false)
        XCTAssertEqual(source.filterCommand(forKeyword: "go")?.manifest.name, "go")
    }

    func testKeywordlessFilterCommandFallsBackToName() throws {
        try writeCommand("picker", title: "Picker", mode: "filter", keywords: [])
        let source = CommandSource(store: store(), autoReload: false)
        let item = source.items(matching: "").first
        XCTAssertEqual(item?.action,
                       .enterFilter(keyword: "picker", commandName: "picker"))
        // Routing must honor the same fallback — otherwise submitting the
        // row expands to "picker " that resolves to nothing.
        XCTAssertEqual(source.filterCommand(forKeyword: "picker")?.manifest.name,
                       "picker")
        // And the name must be searchable — it is the visible trigger word.
        XCTAssertTrue(item?.matchText.contains("picker") ?? false)
    }

    func testActionCommandIsNotAFilterCommand() throws {
        try writeCommand("act", title: "Act", keywords: ["act"])
        let source = CommandSource(store: store(), autoReload: false)
        XCTAssertNil(source.filterCommand(forKeyword: "act"))
    }

    /// `<trigger> <rest>` binds the remainder to an action command's
    /// args — the query-level path that makes the manifest's `arguments`
    /// contract reachable (PLAN §4.1).
    func testActionCommandBindsQueryRemainderAsArgs() throws {
        try writeCommand("resize", title: "Resize", keywords: ["rsz"])
        let source = CommandSource(store: store(), autoReload: false)

        // Name and first keyword both trigger the binding.
        XCTAssertEqual(source.items(matching: "resize 50%").first?.action,
                       .runCommand("resize", ["50%"]))
        XCTAssertEqual(source.items(matching: "rsz 640x480").first?.action,
                       .runCommand("resize", ["640x480"]))
        // The remainder is one arg — inner spaces preserved, ends trimmed.
        XCTAssertEqual(source.items(matching: "resize  50%  wide ").first?.action,
                       .runCommand("resize", ["50%  wide"]))
        // Case-insensitive trigger: the row runs regardless of case, so
        // a strict match would silently run it without the user's args.
        XCTAssertEqual(source.items(matching: "Resize 50%").first?.action,
                       .runCommand("resize", ["50%"]))
        XCTAssertEqual(source.items(matching: "RSZ 640x480").first?.action,
                       .runCommand("resize", ["640x480"]))
    }

    /// A bare trigger (or a whitespace-only rest) binds no args — the row
    /// is a plain run, same as before.
    func testActionCommandBareTriggerBindsNoArgs() throws {
        try writeCommand("resize", title: "Resize", keywords: ["rsz"])
        let source = CommandSource(store: store(), autoReload: false)

        XCTAssertEqual(source.items(matching: "resize").first?.action,
                       .runCommand("resize", []))
        XCTAssertEqual(source.items(matching: "resize   ").first?.action,
                       .runCommand("resize", []))
        // A first token that isn't this command's trigger binds nothing.
        XCTAssertEqual(source.items(matching: "res 50%").first?.action,
                       .runCommand("resize", []))
    }

    /// Filter-mode commands keep their `.enterFilter` action regardless
    /// of a query's shape — their remainder routes through filter mode.
    func testFilterCommandNeverBindsArgs() throws {
        try writeCommand("emoji", title: "Emoji Picker", mode: "filter",
                         keywords: ["em"])
        let source = CommandSource(store: store(), autoReload: false)
        XCTAssertEqual(source.items(matching: "em fire").first?.action,
                       .enterFilter(keyword: "em", commandName: "emoji"))
    }

    /// The app's ordering: the store starts watching at launch and the
    /// panel's source comes up while the initial pass is in flight. The
    /// publish is delivered on main, so it cannot land between these
    /// synchronous statements — the source must still catch it.
    func testWatchedInitialScanReloadsWiredSource() throws {
        try writeCommand("fresh", title: "Fresh")
        let store = CommandStore(rootPaths: [root.path])
        store.startWatching()
        let source = CommandSource(store: store, autoReload: false)
        let reloaded = expectation(description: "source reload")
        source.onReload = { reloaded.fulfill() }

        wait(for: [reloaded], timeout: 2)

        XCTAssertEqual(source.items(matching: "").map(\.title), ["Fresh"])
        store.stopWatching()
    }

    /// A source created after the initial publish already fired — a lazily
    /// built panel — must read the committed snapshot immediately and still
    /// receive later publishes. `items(matching:)` reads `store.commands`
    /// live, so there is no snapshot to hydrate and no empty window.
    func testSourceCreatedAfterInitialPublishReadsCommittedState() throws {
        try writeCommand("fresh", title: "Fresh")
        let store = CommandStore(rootPaths: [root.path])
        let initial = expectation(description: "initial publish")
        store.onChange = { _ in initial.fulfill() }
        store.startWatching()
        wait(for: [initial], timeout: 2)

        let source = CommandSource(store: store, autoReload: false)
        XCTAssertEqual(source.items(matching: "").map(\.title), ["Fresh"])

        let reloaded = expectation(description: "source reload")
        source.onReload = { reloaded.fulfill() }
        try writeCommand("beta", title: "Beta")
        store.scan()
        wait(for: [reloaded], timeout: 2)
        XCTAssertEqual(source.items(matching: "").map(\.title),
                       ["Beta", "Fresh"])
        store.stopWatching()
    }

    // MARK: Helpers

    private func store() -> CommandStore {
        let store = CommandStore(rootPaths: [root.path])
        store.scan()
        return store
    }

    private func writeCommand(_ name: String, title: String,
                              mode: String = "action",
                              keywords: [String] = []) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "schemaVersion": 1, "name": name, "title": title,
            "runtime": "js", "entry": "main.js", "mode": mode,
            "keywords": keywords,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: directory.appendingPathComponent("command.json"),
                       options: .atomic)
        try "async function run() {}".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true, encoding: .utf8)
    }
}
