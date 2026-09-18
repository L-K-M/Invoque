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
