import XCTest
@testable import Invoque

final class CommandStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testScanFindsValidCommandsAndReportsInvalid() throws {
        try writeCommand("beta", title: "Beta")
        try writeCommand("alpha", title: "Alpha")
        // Invalid: the manifest fails validation (schemaVersion 2).
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try """
        { "schemaVersion": 2, "name": "broken", "title": "Broken" }
        """.write(to: broken.appendingPathComponent("command.json"),
                  atomically: true, encoding: .utf8)
        // A stray file at the root is not a command and must be ignored.
        try "hello".write(to: root.appendingPathComponent("README.md"),
                          atomically: true, encoding: .utf8)

        let store = CommandStore(rootPaths: [root.path])
        store.scan()

        // Sorted by title.
        XCTAssertEqual(store.commands.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(store.scanErrors.count, 1)
        XCTAssertEqual(store.scanErrors.first?.directory.lastPathComponent, "broken")
    }

    func testMissingRootYieldsNoCommandsAndNoError() {
        let store = CommandStore(rootPaths: [root.appendingPathComponent("does-not-exist").path])
        store.scan()
        XCTAssertTrue(store.commands.isEmpty)
        XCTAssertTrue(store.scanErrors.isEmpty)
    }

    func testTildeExpansion() {
        let store = CommandStore(rootPaths: ["~/invoque-test-commands"])
        // Not observable directly — but scanning must not crash, and the
        // directory almost certainly doesn't exist.
        store.scan()
        XCTAssertTrue(store.commands.isEmpty)
    }

    // MARK: Helpers

    private func writeCommand(_ name: String, title: String) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 1,
          "name": "\(name)",
          "title": "\(title)",
          "runtime": "js",
          "entry": "main.js",
          "mode": "action"
        }
        """
        try manifest.write(to: directory.appendingPathComponent("command.json"),
                           atomically: true, encoding: .utf8)
        try "async function run() {}".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8)
    }
}
