import XCTest
@testable import Invoque

final class CommandManifestTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
    }

    /// The example manifest from PLAN.md §4.1.
    private let exampleJSON = """
    {
      "schemaVersion": 1,
      "name": "format-clipboard-json",
      "title": "Format Clipboard JSON",
      "description": "Pretty-print the JSON currently on the clipboard",
      "runtime": "js",
      "entry": "main.js",
      "mode": "action",
      "arguments": [{ "name": "indent", "type": "text", "optional": true }],
      "keywords": ["json", "fmt", "pretty"],
      "icon": "curlybraces",
      "permissions": ["clipboard.read", "clipboard.write"],
      "generated": { "prompt": "…", "model": "…", "revision": 2 }
    }
    """

    func testDecodesPlanExample() throws {
        let manifest = try JSONDecoder().decode(CommandManifest.self, from: Data(exampleJSON.utf8))

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.name, "format-clipboard-json")
        XCTAssertEqual(manifest.title, "Format Clipboard JSON")
        XCTAssertEqual(manifest.description, "Pretty-print the JSON currently on the clipboard")
        XCTAssertEqual(manifest.runtime, .js)
        XCTAssertEqual(manifest.entry, "main.js")
        XCTAssertEqual(manifest.mode, .action)
        XCTAssertEqual(manifest.arguments.count, 1)
        XCTAssertEqual(manifest.arguments.first?.name, "indent")
        XCTAssertEqual(manifest.arguments.first?.type, "text")
        XCTAssertEqual(manifest.arguments.first?.optional, true)
        XCTAssertEqual(manifest.keywords, ["json", "fmt", "pretty"])
        XCTAssertEqual(manifest.icon, "curlybraces")
        XCTAssertEqual(manifest.permissions, ["clipboard.read", "clipboard.write"])
        XCTAssertEqual(manifest.grantedPermissions, [.clipboardRead, .clipboardWrite])
        XCTAssertEqual(manifest.generated?.prompt, "…")
        XCTAssertEqual(manifest.generated?.model, "…")
        XCTAssertEqual(manifest.generated?.revision, 2)
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        let manifest = try manifest(overriding: ["schemaVersion": 2])
        let directory = try makeCommandDirectory()
        XCTAssertThrowsError(try manifest.validate(in: directory)) { error in
            XCTAssertEqual(error as? CommandManifest.ValidationError,
                           .unsupportedSchemaVersion(2))
        }
    }

    func testRejectsUnknownPermissions() throws {
        let manifest = try manifest(overriding: [
            "permissions": ["clipboard.read", "teleport"],
        ])
        let directory = try makeCommandDirectory()
        XCTAssertThrowsError(try manifest.validate(in: directory)) { error in
            XCTAssertEqual(error as? CommandManifest.ValidationError,
                           .unknownPermissions(["teleport"]))
        }
    }

    func testRejectsMissingName() {
        let json = """
        { "schemaVersion": 1, "title": "No Name", "entry": "main.js" }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CommandManifest.self,
                                                      from: Data(json.utf8)))
    }

    func testRejectsInvalidName() throws {
        let manifest = try manifest(overriding: ["name": "Bad Name!"])
        let directory = try makeCommandDirectory()
        XCTAssertThrowsError(try manifest.validate(in: directory)) { error in
            XCTAssertEqual(error as? CommandManifest.ValidationError,
                           .invalidName("Bad Name!"))
        }
    }

    func testRejectsNameWithTrailingNewline() throws {
        // ICU's `$` matches before a trailing line terminator — the slug
        // pattern must anchor with \z instead or "format-json\n" validates.
        let manifest = try manifest(overriding: ["name": "format-json\n"])
        let directory = try makeCommandDirectory()
        XCTAssertThrowsError(try manifest.validate(in: directory)) { error in
            XCTAssertEqual(error as? CommandManifest.ValidationError,
                           .invalidName("format-json\n"))
        }
    }

    func testDirectoryNamedManifestIsUnreadable() throws {
        // command.json exists but is a directory — "unreadable", not
        // "missing".
        let directory = try makeCommandDirectory()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("command.json"),
            withIntermediateDirectories: false)
        XCTAssertThrowsError(try Command(directory: directory)) { error in
            XCTAssertEqual(error as? Command.LoadError, .manifestUnreadable)
        }
    }

    func testRejectsMissingEntryFile() throws {
        let manifest = try manifest(overriding: [:])
        let directory = try makeCommandDirectory(writeEntry: false)
        XCTAssertThrowsError(try manifest.validate(in: directory)) { error in
            XCTAssertEqual(error as? CommandManifest.ValidationError,
                           .entryNotFound("main.js"))
        }
    }

    func testRejectsEntryEscapingDirectory() throws {
        let manifest = try manifest(overriding: ["entry": "../outside.js"])
        let directory = try makeCommandDirectory()
        XCTAssertThrowsError(try manifest.validate(in: directory)) { error in
            XCTAssertEqual(error as? CommandManifest.ValidationError,
                           .entryEscapesDirectory("../outside.js"))
        }
    }

    func testRejectsSymlinkedDataDirectory() throws {
        let directory = try makeLoadableCommandDirectory()
        let outside = try makeTemporaryDirectory(prefix: "invoque-outside")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("data"),
            withDestinationURL: outside)

        XCTAssertThrowsError(try Command(directory: directory)) { error in
            XCTAssertEqual(error as? CommandDirectoryPolicy.Violation,
                           .symbolicLink("data"))
        }
    }

    func testRejectsSymlinkedStorageFile() throws {
        let directory = try makeLoadableCommandDirectory()
        let dataDirectory = directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: false)

        let outside = try makeTemporaryDirectory(prefix: "invoque-outside")
        let target = outside.appendingPathComponent("secret.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: dataDirectory.appendingPathComponent("storage.json"),
            withDestinationURL: target)

        XCTAssertThrowsError(try Command(directory: directory)) { error in
            XCTAssertEqual(error as? CommandDirectoryPolicy.Violation,
                           .symbolicLink("data/storage.json"))
        }
    }

    // MARK: Helpers

    /// Decodes the example manifest with selected top-level keys replaced.
    private func manifest(overriding overrides: [String: Any]) throws -> CommandManifest {
        var object = try JSONSerialization.jsonObject(with: Data(exampleJSON.utf8)) as? [String: Any] ?? [:]
        for (key, value) in overrides {
            object[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CommandManifest.self, from: data)
    }

    /// A temp directory containing a main.js so entry validation can pass.
    private func makeCommandDirectory(writeEntry: Bool = true) throws -> URL {
        let directory = try makeTemporaryDirectory(prefix: "invoque-manifest")
        if writeEntry {
            try "async function run() {}".write(
                to: directory.appendingPathComponent("main.js"),
                atomically: true,
                encoding: .utf8)
        }
        return directory
    }

    private func makeLoadableCommandDirectory() throws -> URL {
        let directory = try makeCommandDirectory()
        try exampleJSON.write(
            to: directory.appendingPathComponent("command.json"),
            atomically: true,
            encoding: .utf8)
        return directory
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }
}
