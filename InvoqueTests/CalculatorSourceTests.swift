import XCTest
@testable import Invoque

final class CalculatorSourceTests: XCTestCase {

    private var source: CalculatorSource!

    override func setUp() {
        super.setUp()
        source = CalculatorSource()
    }

    // MARK: Valid expressions

    func testSimpleAddition() {
        let items = source.items(matching: "2+2")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "= 4")
        XCTAssertEqual(items.first?.action, .copyText("4"))
    }

    func testParenthesizedExpression() {
        let items = source.items(matching: "(3+4)*2")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "= 14")
        XCTAssertEqual(items.first?.action, .copyText("14"))
    }

    func testFunctionMidExpression() {
        let items = source.items(matching: "2*sqrt(9)")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "= 6")
    }

    func testLeadingFunctionExpression() {
        // A function-first expression is natural calculator input.
        let items = source.items(matching: "sqrt(9)")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "= 3")
    }

    func testBareFunctionNameRejected() {
        // "exp" passes the prefilter (it prefixes a known function) but
        // never parses without parens — no row, no false positives.
        XCTAssertTrue(source.items(matching: "exp").isEmpty)
    }

    func testSurroundingWhitespaceIgnored() {
        let items = source.items(matching: "  2 + 2 ")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "= 4")
    }

    // MARK: Rejections

    func testPlainWordRejected() {
        XCTAssertTrue(source.items(matching: "hello").isEmpty)
    }

    // MARK: Base conversions

    func testDecimalToHexConversion() throws {
        let item = try XCTUnwrap(source.items(matching: "255").first)
        XCTAssertEqual(item.title, "255 = 0xFF")
        XCTAssertTrue(item.subtitle.contains("Hex 0xFF"))
        XCTAssertTrue(item.subtitle.contains("Bin 0b11111111"))
        XCTAssertTrue(item.subtitle.contains("Oct 0o377"))
        XCTAssertEqual(item.action, .copyText("0xFF"))
        // The id rides the calc: namespace — a head pin, frecency-ineligible.
        XCTAssertEqual(item.id, "calc:base:255")
    }

    func testHexLiteralToDecimal() throws {
        let item = try XCTUnwrap(source.items(matching: "0xFF").first)
        XCTAssertEqual(item.title, "0xFF = 255")
        XCTAssertEqual(item.action, .copyText("255"))
        // Same value, same row identity as the decimal form.
        XCTAssertEqual(item.id, "calc:base:255")
    }

    func testBinaryLiteralToDecimal() throws {
        let item = try XCTUnwrap(source.items(matching: "0b1010").first)
        XCTAssertEqual(item.title, "0b1010 = 10")
        XCTAssertEqual(item.action, .copyText("10"))
    }

    func testOctalLiteralToDecimal() throws {
        let item = try XCTUnwrap(source.items(matching: "0o17").first)
        XCTAssertEqual(item.title, "0o17 = 15")
        XCTAssertEqual(item.action, .copyText("15"))
    }

    func testUppercasePrefixesResolve() throws {
        let item = try XCTUnwrap(source.items(matching: "0X1A").first)
        XCTAssertEqual(item.title, "0X1A = 26")
        XCTAssertEqual(item.action, .copyText("26"))
    }

    /// A single digit is likelier an app-search fragment than a
    /// conversion request — and the row is a head pin that would outrank
    /// real matches — so decimal input needs two digits.
    func testSingleDigitDecimalStaysASearch() {
        XCTAssertTrue(source.items(matching: "7").isEmpty)
    }

    func testMalformedLiteralsRejected() {
        XCTAssertTrue(source.items(matching: "0x").isEmpty)
        XCTAssertTrue(source.items(matching: "0xG1").isEmpty)
        XCTAssertTrue(source.items(matching: "0b12").isEmpty)
        XCTAssertTrue(source.items(matching: "0o9").isEmpty)
    }

    func testOverflowingValuesRejected() {
        XCTAssertTrue(source.items(
            matching: "99999999999999999999999999").isEmpty)
    }

    // MARK: Rejections

    func testBareGroupRejected() {
        XCTAssertTrue(source.items(matching: "(5)").isEmpty)
    }

    func testShellCommandRejected() {
        XCTAssertTrue(source.items(matching: "rm -rf /").isEmpty)
    }

    func testExpressionWithShellSuffixRejected() {
        XCTAssertTrue(source.items(matching: "2+2; rm -rf /").isEmpty)
    }

    func testUnbalancedParensRejected() {
        XCTAssertTrue(source.items(matching: "(2+2").isEmpty)
        XCTAssertTrue(source.items(matching: "2+2)").isEmpty)
    }

    func testUnknownFunctionRejected() {
        XCTAssertTrue(source.items(matching: "2+foo(3)").isEmpty)
    }

    func testMultiArgumentCallRejected() {
        // Only single-argument functions are implemented, and the comma has
        // no token, so multi-argument calls fail tokenizing.
        XCTAssertTrue(source.items(matching: "2+sqrt(2,3)").isEmpty)
    }

    func testUndocumentedOperatorsDeclined() {
        // `%` passes the charset gate but has no token, and `**` fails to
        // parse; declining them beats guessing at a meaning.
        XCTAssertTrue(source.items(matching: "10%3").isEmpty)
        XCTAssertTrue(source.items(matching: "2**3").isEmpty)
    }

    func testDivisionByZeroRejected() {
        // Non-finite results offer no row rather than `inf`.
        XCTAssertTrue(source.items(matching: "1/0").isEmpty)
    }

    func testEmptyQueryRejected() {
        XCTAssertTrue(source.items(matching: "").isEmpty)
        XCTAssertTrue(source.items(matching: "   ").isEmpty)
    }
}
