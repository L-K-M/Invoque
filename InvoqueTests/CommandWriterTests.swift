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
        let (generation, _) = try generation(
            source: "async function run() { return { title: \"x\" }; }",
            extraFiles: ["lib/util.js": "function h() {}"])
        let directory = try CommandWriter(rootURL: root)
            .save(generation, prompt: "make a demo", model: "m1")

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
        let (generation, _) = try generation()
        let directory = try CommandWriter(rootURL: root)
            .save(generation, prompt: "p", model: "m")
        let written = fileContents(directory, "command.json") ?? ""
        // Sorted keys: name < permissions < runtime < schemaVersion < title.
        guard let nameIndex = written.range(of: "\"name\""),
              let titleIndex = written.range(of: "\"title\""),
              let schemaIndex = written.range(of: "\"schemaVersion\"") else {
            return XCTFail("manifest keys missing: \(written)")
        }
        // name < schemaVersion is the discriminating pair — it fails for
        // declaration-order output, which the title comparisons can't.
        XCTAssertTrue(nameIndex.lowerBound < schemaIndex.lowerBound)
        XCTAssertTrue(nameIndex.lowerBound < titleIndex.lowerBound)
        XCTAssertTrue(schemaIndex.lowerBound < titleIndex.lowerBound)
        XCTAssertTrue(written.hasSuffix("\n"))
    }

    // MARK: Update

    func testUpdateSnapshotsHistoryAndBumpsRevision() throws {
        let writer = CommandWriter(rootURL: root)
        let (v1, _) = try generation(source: "async function run() { return { title: \"v1\" }; }")
        try writer.save(v1, prompt: "first", model: "m1")

        let (v2, _) = try generation(source: "async function run() { return { title: \"v2\" }; }")
        let directory = try writer.save(v2, prompt: "second", model: "m2")

        let history = directory.appendingPathComponent("history")
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: history.path)
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = history.appendingPathComponent(snapshots[0])
        // Snapshot holds the previous command.json + main.js — decode it
        // rather than string-matching encoder whitespace.
        let snapshotManifest = try JSONDecoder().decode(
            CommandManifest.self,
            from: Data((fileContents(snapshot, "command.json") ?? "").utf8))
        XCTAssertEqual(snapshotManifest.generated?.revision, 1)
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

        let (generation, _) = try generation(source: "async function run() {}")
        try CommandWriter(rootURL: root)
            .save(generation, prompt: "p", model: "m")

        let reloaded = try Command(directory: directory)
        XCTAssertEqual(reloaded.manifest.generated?.revision, 1)
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("history").path)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(fileContents(directory.appendingPathComponent("history")
            .appendingPathComponent(snapshots[0]), "main.js")?.contains("handwritten") == true)
    }

    /// Saving is pure file I/O — generated code is never executed (AGENTS.md).
    /// A top-level infinite loop hangs the test the moment `save` ever
    /// evaluates the source — the proof is in the fixture, not the absence
    /// of a marker.
    func testSaveNeverRunsGeneratedCode() throws {
        let source = """
        // If this executed, save would hang — proving generated code never runs.
        while (true) {}
        async function run() {}
        """
        let (generation, _) = try generation(source: source)
        let directory = try CommandWriter(rootURL: root)
            .save(generation, prompt: "p", model: "m")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(contents), ["command.json", "main.js", "data"])
    }

    /// The full loop: after a save, `CommandStore.scan()` picks the command
    /// up — the same path the app takes after the Maker writes.
    func testSavedCommandAppearsInStoreScan() throws {
        let (generation, _) = try generation(name: "fresh-cmd")
        try CommandWriter(rootURL: root)
            .save(generation, prompt: "p", model: "m")
        let store = CommandStore(rootPaths: [root.path])
        store.scan()
        XCTAssertEqual(store.commands.map(\.name), ["fresh-cmd"])
        XCTAssertTrue(store.scanErrors.isEmpty)
    }

    // MARK: Defense

    func testSaveRejectsSymlinkedDataDirectory() throws {
        let directory = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try "unchanged".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("data"),
            withDestinationURL: outside)

        let (generation, _) = try generation()
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            XCTAssertNotNil(error as? CommandWriter.SaveError)
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("command.json").path))
    }

    func testSaveRejectsSymlinkedGeneratedPathComponent() throws {
        let directory = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("lib"),
            withDestinationURL: outside)

        let (generation, _) = try generation(extraFiles: ["lib/util.js": "escaped"])
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            XCTAssertNotNil(error as? CommandWriter.SaveError)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("util.js").path))
    }

    /// An unsafe name on a later file must abort the save before anything
    /// lands — no manifest, no snapshot, no directory.
    func testUnsafeExtraFileNameWritesNothing() throws {
        let (generation, _) = try generation(
            extraFiles: ["../escape.txt": "x"])
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            XCTAssertEqual(error as? CommandWriter.SaveError,
                           .unsafeFileName("../escape.txt"))
        }
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: root.path), [])
    }

    /// Reserved command-owned names can't arrive as generated files either.
    func testReservedFileNameWritesNothing() throws {
        let (generation, _) = try generation(
            extraFiles: ["data/seed.json": "{}"])
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            XCTAssertEqual(error as? CommandWriter.SaveError,
                           .unsafeFileName("data/seed.json"))
        }
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: root.path), [])
    }

    /// APFS is case-insensitive: a `Command.JSON` extra file would silently
    /// overwrite the normalized manifest — it's rejected like any other
    /// unsafe name, before anything lands.
    func testCaseVariantOfCommandJSONIsRejected() throws {
        let (generation, _) = try generation(
            extraFiles: ["Command.JSON": "{\"evil\": true}"])
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            XCTAssertEqual(error as? CommandWriter.SaveError,
                           .unsafeFileName("Command.JSON"))
        }
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: root.path), [])
    }

    /// A manifest entry that isn't among the generated files fails before
    /// a single byte lands.
    func testMissingEntryWritesNothing() throws {
        let json = manifestJSON().replacingOccurrences(of: "\"main.js\"",
                                                       with: "\"index.js\"")
        let generation = GeneratedCommand(
            manifestJSON: json, entryName: "main.js",
            entrySource: "async function run() {}", extraFiles: [:])
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            XCTAssertEqual(error as? CommandWriter.SaveError,
                           .entryNotPresent("index.js"))
        }
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: root.path), [])
    }

    /// Two names differing only by case collide on case-insensitive APFS —
    /// the second write would silently replace the first, so the pair is
    /// rejected before anything lands.
    func testCaseVariantFileNamesAreRejected() throws {
        let (generation, _) = try generation(
            extraFiles: ["Readme.md": "a", "readme.md": "b"])
        XCTAssertThrowsError(
            try CommandWriter(rootURL: root)
                .save(generation, prompt: "p", model: "m")
        ) { error in
            guard case CommandWriter.SaveError.unsafeFileName = error else {
                return XCTFail("expected unsafeFileName, got \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: root.path), [])
    }

    /// A regeneration that drops a file must remove it — otherwise the
    /// directory silently diverges from what was reviewed and approved.
    /// Removal is a move into the revision's history snapshot, not a
    /// delete: the dropped file stays recoverable.
    func testUpdatePrunesFilesTheNewRevisionDropped() throws {
        let writer = CommandWriter(rootURL: root)
        let (v1, _) = try generation(
            extraFiles: ["helpers.js": "function h() {}"])
        let directory = try writer.save(v1, prompt: "p", model: "m")
        XCTAssertNotNil(fileContents(directory, "helpers.js"))

        let (v2, _) = try generation()
        try writer.save(v2, prompt: "p2", model: "m2")
        XCTAssertNil(fileContents(directory, "helpers.js"))
        // data/ and history/ are runtime state and always survive.
        let items = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(items.contains("data"))
        XCTAssertTrue(items.contains("history"))
        // The prune was a move into the revision-2 snapshot — the dropped
        // file is recoverable, not deleted.
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("history").path)
        let moved = snapshots.contains {
            fileContents(directory.appendingPathComponent("history")
                .appendingPathComponent($0), "helpers.js") != nil
        }
        XCTAssertTrue(moved, "dropped file should live in a snapshot: \(snapshots)")
    }

    /// Dropped files nested in a kept directory are pruned too — v2 still
    /// ships lib/, but util.js that only v1 had is stale.
    func testUpdatePrunesNestedDroppedFiles() throws {
        let writer = CommandWriter(rootURL: root)
        let (v1, _) = try generation(extraFiles: [
            "lib/util.js": "function u() {}",
            "lib/helper.js": "function h() {}",
        ])
        let directory = try writer.save(v1, prompt: "p", model: "m")
        XCTAssertNotNil(fileContents(directory, "lib/util.js"))

        let (v2, _) = try generation(extraFiles: [
            "lib/helper.js": "function h() {}",
        ])
        try writer.save(v2, prompt: "p2", model: "m2")
        XCTAssertNil(fileContents(directory, "lib/util.js"))
        XCTAssertNotNil(fileContents(directory, "lib/helper.js"))
    }

    /// Files the user dropped in themselves move to the snapshot rather
    /// than being deleted — a notes.md survives regeneration.
    func testUpdateMovesUserFilesToSnapshot() throws {
        let writer = CommandWriter(rootURL: root)
        let (v1, _) = try generation()
        let directory = try writer.save(v1, prompt: "p", model: "m")
        try "keep me".write(to: directory.appendingPathComponent("notes.md"),
                            atomically: true, encoding: .utf8)

        let (v2, _) = try generation(
            source: "async function run() { return { title: \"v2\" }; }")
        try writer.save(v2, prompt: "p2", model: "m2")
        XCTAssertNil(fileContents(directory, "notes.md"))
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("history").path)
        let moved = snapshots.contains {
            fileContents(directory.appendingPathComponent("history")
                .appendingPathComponent($0), "notes.md") == "keep me"
        }
        XCTAssertTrue(moved, "user file should live in a snapshot: \(snapshots)")
    }

    /// A renamed entry is the prune's collision case: the snapshot already
    /// holds `index.js` (the old entry), so the live one can't move there —
    /// it must be removed outright, or the stale file survives silently.
    func testRenamedEntryPrunesOldEntryFile() throws {
        let writer = CommandWriter(rootURL: root)
        let v1JSON = manifestJSON()
            .replacingOccurrences(of: "\"main.js\"", with: "\"index.js\"")
        let v1 = GeneratedCommand(
            manifestJSON: v1JSON, entryName: "index.js",
            entrySource: "async function run() { return { title: \"v1\" }; }",
            extraFiles: [:])
        let directory = try writer.save(v1, prompt: "p", model: "m")
        XCTAssertNotNil(fileContents(directory, "index.js"))

        let (v2, _) = try generation()
        try writer.save(v2, prompt: "p2", model: "m2")
        XCTAssertNil(fileContents(directory, "index.js"))
        XCTAssertNotNil(fileContents(directory, "main.js"))
    }

    /// A hand-authored command's extra files aren't the generation's to
    /// prune — only maker-generated directories converge.
    func testUpdateKeepsHandAuthoredExtraFiles() throws {
        let directory = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try manifestJSON().write(to: directory.appendingPathComponent("command.json"),
                                 atomically: true, encoding: .utf8)
        try "async function run() {}".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true, encoding: .utf8)
        try "function mine() {}".write(
            to: directory.appendingPathComponent("mine.js"),
            atomically: true, encoding: .utf8)

        let (generation, _) = try generation()
        try CommandWriter(rootURL: root)
            .save(generation, prompt: "p", model: "m")
        XCTAssertNotNil(fileContents(directory, "mine.js"))
    }

    /// A write failure mid-save restores the snapshotted manifest and
    /// entry — the directory must not end up with old manifest + new code.
    func testFailedUpdateRestoresManifestAndEntry() throws {
        let writer = CommandWriter(rootURL: root)
        let (v1, _) = try generation(
            source: "async function run() { return { title: \"v1\" }; }")
        let directory = try writer.save(v1, prompt: "p", model: "m")
        let originalManifest = fileContents(directory, "command.json")
        let originalEntry = fileContents(directory, "main.js")

        let (v2, _) = try generation(
            source: "async function run() { return { title: \"v2\" }; }")
        XCTAssertThrowsError(
            try writer.save(v2, prompt: "p2", model: "m2",
                            fileManager: FailOnDataDirectory()))
        XCTAssertEqual(fileContents(directory, "command.json"), originalManifest)
        XCTAssertEqual(fileContents(directory, "main.js"), originalEntry)
    }

    /// Fails when the save reaches `data/` — after the file writes, before
    /// the manifest commit, the exact mixed-revision window.
    private final class FailOnDataDirectory: FileManager {
        override func createDirectory(
            at url: URL, withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]? = nil) throws {
            if url.lastPathComponent == "data" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.createDirectory(
                at: url, withIntermediateDirectories: createIntermediates,
                attributes: attributes)
        }
    }
}
