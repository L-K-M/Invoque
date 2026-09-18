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
        // Retained prose is intentional: the validator's JS syntax gate is
        // what rejects it — the parser stays lossless.
        XCTAssertTrue(parsed.entrySource.contains("Let me know"))
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
                           .duplicateEntry)
        }
    }

    /// Two `main.js` fences hit the same distinct failure — the model
    /// emitted the entry twice, not two candidates.
    func testFencedDuplicateEntryThrows() {
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```js
        \(mainJS)
        ```
        ```javascript
        \(mainJS)
        ```
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure,
                           .duplicateEntry)
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

    // MARK: Mixed output

    /// A prose separator like `--- 1 ---` looks like a delimiter header —
    /// when the delimited pass can't produce the pair, fences get a shot.
    func testFenceFallbackWhenProseLineLooksLikeHeader() throws {
        let output = """
        --- 1 ---
        ```json
        \(manifestJSON)
        ```
        ```js
        \(mainJS)
        ```
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
    }

    /// A genuinely delimited response missing its entry reports the
    /// delimiter-mode error, not whatever the fence retry produced.
    func testDelimitedMissingEntryKeepsOriginalError() {
        XCTAssertThrowsError(
            try GenerationParser.parse("--- command.json ---\n\(manifestJSON)")
        ) { error in
            XCTAssertEqual(error as? GenerationParser.Failure,
                           .missingEntryFile)
        }
    }

    /// Four-backtick fences are a common model habit — they must parse,
    /// with both the opener and the all-backtick closer accepted.
    func testFourBacktickFences() throws {
        let output = """
        ````json
        \(manifestJSON)
        ````
        ````javascript
        \(mainJS)
        ````
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
        XCTAssertTrue(parsed.extraFiles.isEmpty)
    }

    /// Pathological names can't ride in on a fence tag or a delimiter.
    func testUnsafeNamesAreRejectedOrIgnored() throws {
        // An explicit `lang:path` tag is a deliberate file claim — a bad
        // one is an error, not silence.
        let output = """
        ```json
        \(manifestJSON)
        ```
        ```js:lib/
        \(mainJS)
        ```
        """
        XCTAssertThrowsError(try GenerationParser.parse(output)) { error in
            XCTAssertEqual(error as? GenerationParser.Failure,
                           .invalidFileName("lib/"))
        }
    }

    /// A triple-backtick span that closes on the same line is inline code
    /// in prose, not a fence opener — the real fences still parse.
    func testInlineCodeSpanAtLineStartIsNotAFence() throws {
        let output = """
        ```main.js``` is the entry point
        ```json
        \(manifestJSON)
        ```
        ```javascript
        \(mainJS)
        ```
        """
        let parsed = try GenerationParser.parse(output)
        XCTAssertEqual(parsed.entrySource, mainJS)
    }
}
