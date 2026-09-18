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
    }

    func testFilterCommandItemEntersFilterMode() throws {
        try writeCommand("emoji", title: "Emoji Picker", mode: "filter",
                         keywords: ["em"])
        let source = CommandSource(store: store(), autoReload: false)
        let item = source.items(matching: "").first

        XCTAssertEqual(item?.action, .enterFilter(keyword: "em"))
        XCTAssertEqual(source.filterCommand(forKeyword: "em")?.manifest.name, "emoji")
        XCTAssertNil(source.filterCommand(forKeyword: "nope"))
    }

    func testKeywordlessFilterCommandFallsBackToName() throws {
        try writeCommand("picker", title: "Picker", mode: "filter", keywords: [])
        let source = CommandSource(store: store(), autoReload: false)
        XCTAssertEqual(source.items(matching: "").first?.action,
                       .enterFilter(keyword: "picker"))
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
        let keywordJSON = keywords.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        {
          "schemaVersion": 1, "name": "\(name)", "title": "\(title)",
          "runtime": "js", "entry": "main.js", "mode": "\(mode)",
          "keywords": [\(keywordJSON)]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("command.json"),
                           atomically: true, encoding: .utf8)
        try "async function run() {}".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true, encoding: .utf8)
    }
}
