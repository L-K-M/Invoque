import XCTest
@testable import Invoque

final class GenerationParserTests: XCTestCase {

    private let manifestJSON = """
    { "schemaVersion": 1, "name": "demo", "title": "Demo" }
    """
    private let mainJS = "export default async function run() { return { title: \"hi\" }; }"

    // MARK: Delimiter format

    func testDelimiterFormat() throws {
        let output = """
        --- command.json ---
        \(manifestJSON)
        --- main.js ---
        \(mainJS)
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.manifestJSON, manifestJSON)
        XCTAssertEqual(parsed.entryName, "main.js")
        XCTAssertEqual(parsed.entrySource, mainJS)
        XCTAssertTrue(parsed.extraFiles.isEmpty)
    }

    func testDelimiterFormatIgnoresPreambleAndTrailingProse() throws {
        let output = """
        Sure! Here's your command:
        --- command.json ---
        \(manifestJSON)
        --- main.js ---
        \(mainJS)

        Let me know if you want changes.
        """
        // Trailing prose lands in the last file's block — trimmed trailing
        // newlines only, so the text stays; the file content still parses.
        let parsed = try GenerationParser.parse(output)
        XCTAssertTrue(parsed.entrySource.hasPrefix(mainJS))
    }

    func testDelimiterFormatWithExtraFiles() throws {
        let output = """
        --- command.json ---
        \(manifestJSON)
        --- main.js ---
        \(mainJS)
        --- lib/util.js ---
        function helper() { return 1; }
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.extraFiles["lib/util.js"],
                       "function helper() { return 1; }")
    }

    func testDelimiterDuplicateManifestThrows() {
        let output = """
        --- command.json ---
        \(manifestJSON)
        --- command.json ---
        \(manifestJSON)
        --- main.js ---
        \(mainJS)
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure, .multipleManifests)
        }
    }

    func testDelimiterDuplicateEntryThrows() {
        let output = """
        --- command.json ---
        \(manifestJSON)
        --- main.js ---
        \(mainJS)
        --- main.js ---
        \(mainJS)
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure,
                           .multipleEntryFiles(["main.js"]))
        }
    }

    // MARK: Markdown fences

    func testFencedFormat() throws {
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```javascript
        \(mainJS)
        ```
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.manifestJSON, manifestJSON)
        XCTAssertEqual(parsed.entryName, "main.js")
        XCTAssertEqual(parsed.entrySource, mainJS)
    }

    func testFencedFormatAcceptsJsTagAndProse() throws {
        let output = """
        Here you go:
        ```json
        \(manifestJSON)
        ```
        and the code:
        ```js
        \(mainJS)
        ```
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
    }

    func testFencedFormatHonorsExplicitNames() throws {
        let output = """
        ```json:command.json
        \(manifestJSON)
        ```
        ```js:lib/util.js
        function helper() {}
        ```
        ```js:main.js
        \(mainJS)
        ```
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entryName, "main.js")
        XCTAssertEqual(parsed.extraFiles["lib/util.js"], "function helper() {}")
    }

    func testWrongFenceLanguageYieldsNoEntry() {
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```typescript
        const x: number = 1;
        ```
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure, .missingEntryFile)
        }
    }

    func testTwoUnnamedJsonFencesThrow() {
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```json
        \(manifestJSON)
        ```
        ```js
        \(mainJS)
        ```
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure, .multipleManifests)
        }
    }

    func testUnclosedFenceStillYieldsFile() throws {
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```js
        \(mainJS)
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
    }

    // MARK: Missing / ambiguous halves

    func testMissingManifestThrows() {
        let output = """
        --- main.js ---
        \(mainJS)
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure, .missingManifest)
        }
    }

    func testMissingEntryThrows() {
        XCTAssertThrowsError(try GenerationParser.parse("--- command.json ---\n\(manifestJSON)")) { error in
            XCTAssertEqual(error as? GenerationParser.Failure, .missingEntryFile)
        }
    }

    func testEmptyOutputThrows() {
        XCTAssertThrowsError(try GenerationParser.parse("   \n \n")) { error in
            XCTAssertEqual(error as? GenerationParser.Failure, .empty)
        }
    }

    func testTwoJsFilesWithoutMainThrows() {
        let output = """
        --- command.json ---
        \(manifestJSON)
        --- a.js ---
        \(mainJS)
        --- b.js ---
        \(mainJS)
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            guard case .multipleEntryFiles = error as? GenerationParser.Failure else {
                return XCTFail("expected multipleEntryFiles, got \(error)")
            }
        }
    }

    /// A sole non-main.js file resolves as the entry — the manifest may
    /// declare `entry: "index.js"`.
    func testSingleNonMainJsFileBecomesEntry() throws {
        let output = """
        --- command.json ---
        \(manifestJSON)
        --- index.js ---
        \(mainJS)
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entryName, "index.js")
    }

    // MARK: Robustness

    func testCRLFLineEndings() throws {
        let output = "--- command.json ---\r\n\(manifestJSON)\r\n--- main.js ---\r\n\(mainJS)\r\n"
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
    }

    func testExplicitInvalidFileNameThrows() {
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```js:../escape.js
        \(mainJS)
        ```
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure,
                           .invalidFileName("../escape.js"))
        }
    }

    func testEscapeDelimiterHeaderIsIgnoredAsProse() throws {
        // `--- ../evil.js ---` is not a plausible name, so it's not a header;
        // the entry remains the real main.js block.
        let output = """
        --- ../evil.js ---
        sneaky
        --- command.json ---
        \(manifestJSON)
        --- main.js ---
        \(mainJS)
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
    }
}
