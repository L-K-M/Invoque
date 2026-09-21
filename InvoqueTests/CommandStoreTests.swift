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

    func testStartWatchingPublishesInitialScan() throws {
        try writeCommand("alpha", title: "Alpha")
        let store = CommandStore(rootPaths: [root.path])
        let published = expectation(description: "initial command snapshot")
        // The panel wires its model after startWatching returns; a
        // synchronous first publish would run against a half-wired model.
        var publishedEarly = false
        store.onChange = { commands in
            publishedEarly = true
            XCTAssertTrue(Thread.isMainThread)
            guard commands.map(\.name) == ["alpha"] else { return }
            published.fulfill()
        }

        store.startWatching()
        XCTAssertFalse(publishedEarly,
                       "startWatching must return before the first snapshot publishes")
        wait(for: [published], timeout: 2)

        XCTAssertEqual(store.commands.map(\.name), ["alpha"])
        store.stopWatching()
    }

    /// A stop/start cycle mid-flight must not let the first pass's commit
    /// land after `stopWatching()` — the restarted initial pass republishes.
    func testRestartWatchingPublishesFreshSnapshot() throws {
        try writeCommand("alpha", title: "Alpha")
        let store = CommandStore(rootPaths: [root.path])
        let published = expectation(description: "snapshot after restart")
        store.onChange = { commands in
            guard commands.map(\.name) == ["alpha", "beta"] else { return }
            published.fulfill()
        }
        store.startWatching()
        store.stopWatching()
        // Written while the watcher is down: only a restarted pass that
        // re-walks disk can publish this — a stale first-pass snapshot can't.
        try writeCommand("beta", title: "Beta")
        store.startWatching()
        wait(for: [published], timeout: 2)
        XCTAssertEqual(store.commands.map(\.name), ["alpha", "beta"])
        store.stopWatching()
    }

    func testWatchBudgetIsStoreWideAndFairlySplit() throws {
        // Six commands, two nested files each; budget of 4 must give the
        // first four commands one nested target apiece rather than zero
        // (integer division) or everything (first-come-first-served).
        for i in 0..<6 { try writeCommand("cmd\(i)", title: "Cmd \(i)") }
        let store = CommandStore(rootPaths: [root.path], watchTargetLimit: 4)
        store.scan()

        XCTAssertEqual(store.commands.count, 6)
        // 1 root + 6 command dirs + exactly 4 nested targets.
        XCTAssertEqual(store.scanWatchTargets.count, 11)
        // The nested targets span four distinct command directories — a
        // greedy first-come allocation would land both of cmd0's files
        // instead and starve the rest. Compared on paths: URL equality
        // trips on trailing-slash differences between enumerated and
        // hand-built URLs.
        let rootPath = root.standardizedFileURL.path
        let nestedCommandDirs = Set(store.scanWatchTargets
            .map { $0.deletingLastPathComponent().standardizedFileURL }
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path == rootPath })
        XCTAssertEqual(nestedCommandDirs.count, 4)
    }

    func testMissingRootYieldsNoCommandsAndNoError() {
        let store = CommandStore(rootPaths: [root.appendingPathComponent("does-not-exist").path])
        store.scan()
        XCTAssertTrue(store.commands.isEmpty)
        XCTAssertTrue(store.scanErrors.isEmpty)
    }

    func testTildeExpansion() throws {
        // A UUID keeps the path unique across runs and machines — a fixed
        // name could collide with a real directory a developer happens to
        // have, making the test read actual commands. The command must
        // actually load through the "~/…" spelling or the test proves
        // nothing about expansion.
        let name = "invoque-test-\(UUID().uuidString)"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let commandDirectory = home.appendingPathComponent(name)
            .appendingPathComponent("tilde")
        defer { try? FileManager.default.removeItem(at: home.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: commandDirectory,
                                                withIntermediateDirectories: true)
        try """
        { "schemaVersion": 1, "name": "tilde", "title": "Tilde", "runtime": "js", "entry": "main.js", "mode": "action" }
        """.write(to: commandDirectory.appendingPathComponent("command.json"),
                  atomically: true, encoding: .utf8)
        try "async function run() {}".write(
            to: commandDirectory.appendingPathComponent("main.js"),
            atomically: true, encoding: .utf8)

        let store = CommandStore(rootPaths: ["~/\(name)"])
        store.scan()

        XCTAssertEqual(store.commands.map(\.name), ["tilde"])
        XCTAssertTrue(store.scanErrors.isEmpty)
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
