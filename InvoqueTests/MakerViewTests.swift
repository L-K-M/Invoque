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
