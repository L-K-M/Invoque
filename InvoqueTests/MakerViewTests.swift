import XCTest
@testable import Invoque

final class MakerViewTests: XCTestCase {

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

    /// An unmatched quote swallows the remainder — the user's intent is
    /// unambiguous, and a silent third token would be more surprising.
    func testParseArgsUnmatchedQuoteSwallowsRest() {
        XCTAssertEqual(MakerView.parseArgs("--text \"two words"),
                       ["--text", "two words"])
    }
}
