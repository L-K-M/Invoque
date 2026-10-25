import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import Invoque

final class NumbatEvaluatorTests: XCTestCase {
    func testBundledEngineEvaluatesArithmeticFunctionsAndUnits() async throws {
        let evaluator = NumbatEvaluator()
        for (expression, expected) in [
            ("2+2", "4"), ("(3+4)*2", "14"), ("sqrt(9)", "3"),
            ("-5+3", "-2"), ("2^10", "1024"), ("sin(pi/2)", "1"),
            ("2 km -> m", "2000 m"), ("1 MB -> kB", "1000 kB"),
        ] {
            let result = try await evaluator.evaluate(expression)
            XCTAssertEqual(result, expected, expression)
        }
    }

    func testInvalidIncompatibleAndNonFiniteExpressionsHaveNoAnswer() async throws {
        let evaluator = NumbatEvaluator()
        for expression in ["hello", "2+", "(2+2", "2+foo(3)", "1/0", "sqrt(-1)",
                           "1 m + 1 s", "2+2; rm -rf /", "let x = 5", "print(2)",
                           "100 USD -> EUR"] {
            let result = try await evaluator.evaluate(expression)
            XCTAssertNil(result, expression)
        }
    }

    func testMissingBundledHelperIsAnExplicitFailure() async {
        do {
            _ = try await NumbatEvaluator(executableURL: nil).evaluate("2+2")
            XCTFail("missing helper succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Reinstall"))
        }
    }

    func testTimeLimitStopsAStuckHelper() async throws {
        let helper = try makeStuckHelper()
        defer { removeStuckHelper(helper) }
        let started = Date()
        do {
            _ = try await NumbatEvaluator(executableURL: helper, timeLimit: 0.1).evaluate("2+2")
            XCTFail("stuck helper succeeded")
        } catch NumbatEvaluator.Failure.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            try assertHelperWasReaped(helper)
        }
    }

    func testCancellationReapsTheRunningHelper() async throws {
        let helper = try makeStuckHelper()
        defer { removeStuckHelper(helper) }
        let task = Task {
            try await NumbatEvaluator(executableURL: helper, timeLimit: 10).evaluate("2+2")
        }
        // Wait for the actual child, rather than canceling before launch on a slow runner.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: helper.path + ".pid"), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path + ".pid"))
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled calculation succeeded")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1)
            try assertHelperWasReaped(helper)
        }
    }

    private func makeStuckHelper() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-stuck-numbat-\(UUID().uuidString)")
        // No child processes: the evaluator owns and must reap this exact PID.
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\ntrap '' TERM\nwhile :; do :; done\n".utf8)
            .write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func assertHelperWasReaped(_ helper: URL) throws {
        let text = try String(contentsOfFile: helper.path + ".pid", encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func removeStuckHelper(_ helper: URL) {
        try? FileManager.default.removeItem(at: helper)
        try? FileManager.default.removeItem(atPath: helper.path + ".pid")
    }
}
