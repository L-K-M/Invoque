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

    func testSurroundingWhitespaceIgnored() {
        let items = source.items(matching: "  2 + 2 ")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "= 4")
    }

    // MARK: Rejections

    func testPlainWordRejected() {
        XCTAssertTrue(source.items(matching: "hello").isEmpty)
    }

    func testBareNumberRejected() {
        // No operator, nothing to compute.
        XCTAssertTrue(source.items(matching: "42").isEmpty)
    }

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
        // Only single-argument calls evaluate, so an unknown multi-arg
        // selector can never reach NSExpression and raise.
        XCTAssertTrue(source.items(matching: "2+pow(2,3)").isEmpty)
    }

    func testUndocumentedOperatorsDeclined() {
        // `%` and `**` read as math but are not in NSExpression's documented
        // grammar; declining them is safer than risking an exception.
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
