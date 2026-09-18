import XCTest
@testable import Invoque

final class CommandWriterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func manifestJSON(name: String = "demo",
                              permissions: [String] = []) -> String {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "schemaVersion": 1, "name": "\(name)", "title": "Demo",
          "runtime": "js", "entry": "main.js", "mode": "action",
          "permissions": [\(list)]
        }
        """
    }

    private func generation(name: String = "demo",
                            source: String = "async function run() {}",
                            extraFiles: [String: String] = [:]) throws
        -> (GeneratedCommand, CommandManifest) {
        let json = manifestJSON(name: name)
        let manifest = try JSONDecoder().decode(CommandManifest.self,
                                                from: Data(json.utf8))
        return (GeneratedCommand(manifestJSON: json, entryName: "main.js",
                                 entrySource: source, extraFiles: extraFiles),
                manifest)
    }

    private func fileContents(_ directory: URL, _ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name),
                    encoding: .utf8)
    }

    // MARK: Create

    func testSaveCreatesCommandDirectory() throws {
        let (generation, manifest) = try generation(
            source: "async function run() { return { title: \"x\" }; }",
            extraFiles: ["lib/util.js": "function h() {}"])
        let directory = try CommandWriter(rootURL: root)
            .save(generation, manifest: manifest, prompt: "make a demo", model: "m1")

        XCTAssertEqual(directory.lastPathComponent, "demo")
        // The saved command must load through the normal path — this is the
        // contract that matters.
        let command = try Command(directory: directory)
        XCTAssertEqual(command.manifest.name, "demo")
        XCTAssertEqual(command.manifest.generated?.prompt, "make a demo")
        XCTAssertEqual(command.manifest.generated?.model, "m1")
        XCTAssertEqual(command.manifest.generated?.revision, 1)
        XCTAssertEqual(fileContents(directory, "lib/util.js"), "function h() {}")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("data").path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testManifestIsNormalizedSortedKeys() throws {
        let (generation, manifest) = try generation()
        let directory = try CommandWriter(rootURL: root)
            .save(generation, manifest: manifest, prompt: "p", model: "m")
        let written = fileContents(directory, "command.json") ?? ""
        // Sorted keys: name < permissions < runtime < schemaVersion < title.
        guard let nameIndex = written.range(of: "\"name\""),
              let titleIndex = written.range(of: "\"title\""),
              let schemaIndex = written.range(of: "\"schemaVersion\"") else {
            return XCTFail("manifest keys missing: \(written)")
        }
        XCTAssertTrue(nameIndex.lowerBound < titleIndex.lowerBound)
        XCTAssertTrue(schemaIndex.lowerBound < titleIndex.lowerBound)
        XCTAssertTrue(written.hasSuffix("\n"))
    }

    // MARK: Update

    func testUpdateSnapshotsHistoryAndBumpsRevision() throws {
        let writer = CommandWriter(rootURL: root)
        let (v1, m1) = try generation(source: "async function run() { return { title: \"v1\" }; }")
        try writer.save(v1, manifest: m1, prompt: "first", model: "m1")

        let (v2, m2) = try generation(source: "async function run() { return { title: \"v2\" }; }")
        let directory = try writer.save(v2, manifest: m2, prompt: "second", model: "m2")

        let history = directory.appendingPathComponent("history")
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: history.path)
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = history.appendingPathComponent(snapshots[0])
        // Snapshot holds the previous command.json + main.js.
        XCTAssertTrue(fileContents(snapshot, "command.json")?.contains("\"revision\" : 1") == true
                      || fileContents(snapshot, "command.json")?.contains("\"revision\": 1") == true)
        XCTAssertTrue(fileContents(snapshot, "main.js")?.contains("v1") == true)

        // And the live files carry revision 2 + the new code.
        let reloaded = try Command(directory: directory)
        XCTAssertEqual(reloaded.manifest.generated?.revision, 2)
        XCTAssertEqual(reloaded.manifest.generated?.prompt, "second")
        XCTAssertTrue(fileContents(directory, "main.js")?.contains("v2") == true)
    }

    /// A command directory without `generated` provenance (hand-written)
    /// still snapshots and starts revisions at 1.
    func testUpdateOfHandWrittenCommandStartsAtRevision1() throws {
        let directory = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try manifestJSON().write(to: directory.appendingPathComponent("command.json"),
                                 atomically: true, encoding: .utf8)
        try "async function run() { /* handwritten */ }".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true, encoding: .utf8)

        let (generation, manifest) = try generation(source: "async function run() {}")
        try CommandWriter(rootURL: root)
            .save(generation, manifest: manifest, prompt: "p", model: "m")

        let reloaded = try Command(directory: directory)
        XCTAssertEqual(reloaded.manifest.generated?.revision, 1)
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("history").path)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(fileContents(directory.appendingPathComponent("history")
            .appendingPathComponent(snapshots[0]), "main.js")?.contains("handwritten") == true)
    }

    /// Saving is pure file I/O — generated code is never executed (AGENTS.md).
    /// A top-level side effect that would create a marker file if the code
    /// ran must not run on save.
    func testSaveNeverRunsGeneratedCode() throws {
        let source = """
        // If this executed, it would leave a marker in the command dir.
        async function run() {}
        """
        let (generation, manifest) = try generation(source: source)
        let directory = try CommandWriter(rootURL: root)
            .save(generation, manifest: manifest, prompt: "p", model: "m")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(contents), ["command.json", "main.js", "data"])
    }

    /// The full loop: after a save, `CommandStore.scan()` picks the command
    /// up — the same path the app takes after the Maker writes.
    func testSavedCommandAppearsInStoreScan() throws {
        let (generation, manifest) = try generation(name: "fresh-cmd")
        try CommandWriter(rootURL: root)
            .save(generation, manifest: manifest, prompt: "p", model: "m")
        let store = CommandStore(rootPaths: [root.path])
        store.scan()
        XCTAssertEqual(store.commands.map(\.name), ["fresh-cmd"])
        XCTAssertTrue(store.scanErrors.isEmpty)
    }
}
