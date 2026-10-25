import XCTest
@testable import Invoque

final class CalculatorSourceTests: XCTestCase {
    // MARK: Immediate base conversions

    func testBaseConversionsKeepTheirPayloadsAndIdentity() throws {
        let source = CalculatorSource()
        for (query, title, payload) in [
            ("255", "255 = 0xFF", "0xFF"),
            ("0xFF", "0xFF = 255", "255"),
            ("0b1010", "0b1010 = 10", "10"),
            ("0o17", "0o17 = 15", "15"),
            ("0X1A", "0X1A = 26", "26"),
        ] {
            let item = try XCTUnwrap(source.items(matching: query).first)
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.action, .copyText(payload))
        }
        let decimal = try XCTUnwrap(source.items(matching: "255").first)
        XCTAssertEqual(decimal.id, "calc:base:255")
        XCTAssertEqual(decimal.id, source.items(matching: "0xFF").first?.id)
        XCTAssertTrue(decimal.subtitle.contains("Hex 0xFF"))
        XCTAssertTrue(decimal.subtitle.contains("Bin 0b11111111"))
        XCTAssertTrue(decimal.subtitle.contains("Oct 0o377"))
    }

    func testBareNumbersWordsAndIncompleteBaseLiteralsHaveNoImmediateRow() {
        let source = CalculatorSource()
        for query in ["7", "hello", "", "   ", "0x", "0xG1", "0b12", "0o9",
                      "99999999999999999999999999"] {
            XCTAssertTrue(source.items(matching: query).isEmpty, query)
        }
    }

    // MARK: Query recognition

    func testMathUnitsFunctionsAndExplicitExpressionsReachNumbat() {
        for query in ["2+2", "(3+4)*2", "sqrt(9)", "sin(pi/2)", "-5+3", ".5 m -> cm",
                      "30 km/h -> mph", "1 MB -> kB", "pi", "= speed_of_light"] {
            XCTAssertNotNil(CalculatorSource.expression(for: query), query)
        }
        XCTAssertEqual(CalculatorSource.expression(for: "  1 MB -> kB  "), "1 MB -> kB")
        XCTAssertEqual(CalculatorSource.expression(for: "= speed_of_light"), "speed_of_light")
    }

    func testOrdinarySearchesAndControlCharactersDoNotRunAnEngine() {
        for query in ["Safari", "7", "255", "0xFF", "exp", "(5)", "-5", "= ",
                      "2+2\nprint(3)", "2\u{0}+2", String(repeating: "(", count: 201)] {
            XCTAssertNil(CalculatorSource.expression(for: query), query)
        }
    }

    // MARK: Async cache

    @MainActor
    func testAnswerRefreshesOnceAndCopiesOnlyTheResult() async {
        let source = CalculatorSource(evaluator: { expression in
            XCTAssertEqual(expression, "2 km -> m")
            return "2000 m"
        })
        let refreshed = expectation(description: "answer published")
        source.onReload = { refreshed.fulfill() }
        source.update(for: "2 km -> m")
        XCTAssertTrue(source.items(matching: "2 km -> m").isEmpty)
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertFalse(source.isPending)
        XCTAssertEqual(source.items(matching: "2 km -> m").first?.title, "= 2000 m")
        XCTAssertEqual(source.items(matching: "2 km -> m").first?.action, .copyText("2000 m"))
        XCTAssertTrue(source.items(matching: "3 km -> m").isEmpty)
        source.update(for: "2 km -> m")
        XCTAssertFalse(source.isPending, "a source refresh must reuse the completed answer")
    }

    @MainActor
    func testEditDropsAnOldAnswerEvenWhenEvaluationIgnoresCancellation() async {
        let started = expectation(description: "old evaluation started")
        let finished = expectation(description: "new answer published")
        let gate = EvaluationGate(started: started)
        let source = CalculatorSource(evaluator: { expression in
            if expression == "1+1" { return await gate.evaluate() }
            return "4"
        })
        source.update(for: "1+1")
        await fulfillment(of: [started], timeout: 5)
        source.onReload = { finished.fulfill() }
        source.update(for: "2+2")
        await fulfillment(of: [finished], timeout: 5)
        await gate.release()
        // Drain the old task's continuation before inspecting the committed cache.
        await gate.finished()
        XCTAssertEqual(source.items(matching: "2+2").first?.action, .copyText("4"))
        XCTAssertTrue(source.items(matching: "1+1").isEmpty)
    }

    @MainActor
    func testCancelDuringDebounceNeverRunsEvaluator() async throws {
        let source = CalculatorSource(evaluator: { _ in
            XCTFail("cancelled debounce reached Numbat")
            return nil
        })
        source.update(for: "2+2")
        source.cancel()
        try await Task.sleep(nanoseconds: CalculatorSource.debounceNanoseconds * 2)
        XCTAssertFalse(source.isPending)
        XCTAssertTrue(source.items(matching: "2+2").isEmpty)
    }

    @MainActor
    func testInfrastructureFailuresAreVisibleAndInvalidExpressionsAreSilent() async {
        let source = CalculatorSource(evaluator: { _ in throw NumbatEvaluator.Failure.unavailable })
        let failed = expectation(description: "failure published")
        source.onReload = { failed.fulfill() }
        source.update(for: "2+2")
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(source.items(matching: "2+2").first?.title, "Calculator unavailable")
        XCTAssertTrue(source.items(matching: "2+2").first?.subtitle.contains("Reinstall") == true)

        let invalid = CalculatorSource(evaluator: { _ in nil })
        let completed = expectation(description: "invalid expression completed")
        invalid.onReload = { completed.fulfill() }
        invalid.update(for: "2+")
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(invalid.items(matching: "2+").isEmpty)
        invalid.update(for: "2+")
        XCTAssertFalse(invalid.isPending, "invalid queries must not loop on refresh")
    }

    private actor EvaluationGate {
        private let started: XCTestExpectation
        private var continuation: CheckedContinuation<String?, Never>?
        private var didFinish = false

        init(started: XCTestExpectation) { self.started = started }

        func evaluate() async -> String? {
            let result = await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
            didFinish = true
            return result
        }

        func release() {
            continuation?.resume(returning: "2")
            continuation = nil
        }

        func finished() async {
            while !didFinish { await Task.yield() }
        }
    }
}
