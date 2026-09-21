import XCTest
@testable import Invoque

final class MakerViewTests: XCTestCase {

    func testReviewFilesIncludesEveryGeneratedFileInStableOrder() {
        let generation = GeneratedCommand(
            manifestJSON: "manifest",
            entryName: "src/run.js",
            entrySource: "entry",
            extraFiles: ["z.txt": "last", "a.txt": "first"])

        XCTAssertEqual(MakerView.reviewFiles(generation), [
            MakerView.ReviewFile(name: "command.json", contents: "manifest"),
            MakerView.ReviewFile(name: "src/run.js", contents: "entry"),
            MakerView.ReviewFile(name: "a.txt", contents: "first"),
            MakerView.ReviewFile(name: "z.txt", contents: "last"),
        ])
    }

    func testReviewFilesSkipsReservedNameCollisions() {
        let generation = GeneratedCommand(
            manifestJSON: "manifest",
            entryName: "src/run.js",
            entrySource: "entry",
            extraFiles: [
                "command.json": "rogue",
                "src/run.js": "duplicate",
                "b.txt": "ok",
            ])

        XCTAssertEqual(MakerView.reviewFiles(generation).map(\.name), [
            "command.json", "src/run.js", "b.txt",
        ])
    }

    func testReviewFilesDisambiguatesManifestEntryNameCollision() {
        let generation = GeneratedCommand(
            manifestJSON: "manifest",
            entryName: "command.json",
            entrySource: "entry",
            extraFiles: [:])

        XCTAssertEqual(MakerView.reviewFiles(generation), [
            MakerView.ReviewFile(
                name: "command.json (manifest)",
                contents: "manifest"),
            MakerView.ReviewFile(name: "command.json", contents: "entry"),
        ])
    }

    func testStaleSourceSelectionFallsBackToEntry() {
        let files = [
            MakerView.ReviewFile(name: "command.json", contents: "manifest"),
            MakerView.ReviewFile(name: "main.js", contents: "entry"),
        ]

        XCTAssertEqual(MakerView.selectedFile(
            in: files,
            preferred: "removed.js",
            entryName: "main.js"), files[1])
        XCTAssertEqual(MakerView.selectedFile(
            in: files,
            preferred: "command.json",
            entryName: "main.js"), files[0])
    }

    func testStaleSelectionFallsBackToFirstFileWhenEntryMissing() {
        let files = [
            MakerView.ReviewFile(name: "command.json", contents: "manifest"),
        ]

        XCTAssertEqual(MakerView.selectedFile(
            in: files,
            preferred: "removed.js",
            entryName: "also-removed.js"), files[0])
    }

    /// When the entry file is itself named command.json the manifest row is
    /// renamed; a selection holding that renamed id still resolves.
    func testSelectionResolvesRenamedManifest() {
        let generation = GeneratedCommand(
            manifestJSON: "manifest",
            entryName: "command.json",
            entrySource: "entry",
            extraFiles: [:])
        let files = MakerView.reviewFiles(generation)

        XCTAssertEqual(MakerView.selectedFile(
            in: files,
            preferred: "command.json (manifest)",
            entryName: "command.json").contents, "manifest")
    }

    /// An extra file literally named like the disambiguated manifest row is
    /// dropped as reserved — the collision case where a reviewable file is
    /// hidden must stay visible in tests.
    func testReviewFilesDropsManifestAliasCollision() {
        let generation = GeneratedCommand(
            manifestJSON: "manifest",
            entryName: "command.json",
            entrySource: "entry",
            extraFiles: ["command.json (manifest)": "rogue"])

        XCTAssertEqual(MakerView.reviewFiles(generation).map(\.name), [
            "command.json (manifest)", "command.json",
        ])
        XCTAssertEqual(MakerView.reviewFiles(generation).first?.contents,
                       "manifest")
    }

    func testPreviewTextPassesThroughUnderLimit() {
        XCTAssertEqual(MakerView.previewText("small"), "small")
    }

    func testPreviewTextPassesThroughAtLimit() {
        let exact = String(repeating: "x", count: 200_000)
        XCTAssertEqual(MakerView.previewText(exact), exact)
    }

    func testPreviewTextTruncatesOverLimit() {
        let big = String(repeating: "x", count: 200_100)
        let preview = MakerView.previewText(big)
        let suffix = "\n… preview truncated — save to see the full file"
        XCTAssertEqual(preview.count, 200_000 + suffix.count)
        XCTAssertTrue(preview.hasPrefix(String(repeating: "x", count: 200_000)))
        XCTAssertTrue(preview.hasSuffix(suffix))
    }

    // MARK: parseArgs

    func testParseArgsSplitsOnWhitespace() {
        XCTAssertEqual(MakerView.parseArgs("one two  three"),
                       ["one", "two", "three"])
    }

    func testParseArgsHonorsDoubleQuotes() {
        XCTAssertEqual(MakerView.parseArgs("--text \"two words\" tail"),
                       ["--text", "two words", "tail"])
    }

    func testParseArgsHonorsSingleQuotes() {
        XCTAssertEqual(MakerView.parseArgs("--text 'two words'"),
                       ["--text", "two words"])
    }

    func testParseArgsEmptyAndWhitespaceOnly() {
        XCTAssertEqual(MakerView.parseArgs(""), [])
        XCTAssertEqual(MakerView.parseArgs("   "), [])
    }

    /// A quoted empty string is an argument, matching shell semantics —
    /// `--text ""` distinguishes "blank" from "flag absent".
    func testParseArgsKeepsEmptyQuotedArg() {
        XCTAssertEqual(MakerView.parseArgs("--text \"\" tail"),
                       ["--text", "", "tail"])
    }

    /// An unmatched quote swallows the remainder — the user's intent is
    /// unambiguous, and a silent third token would be more surprising.
    func testParseArgsUnmatchedQuoteSwallowsRest() {
        XCTAssertEqual(MakerView.parseArgs("--text \"two words"),
                       ["--text", "two words"])
    }
}
