import XCTest
@testable import Invoque

final class FuzzyMatcherTests: XCTestCase {

    // MARK: Matching

    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score("xyz", candidate: "Safari"))
        XCTAssertNil(FuzzyMatcher.score("safariz", candidate: "Safari"))
        // Partial-match-then-exhaustion: 's'→0 and 'i'→5 match, but no 'r'
        // exists after index 5 — the subsequence walk must fail, not just
        // the length check.
        XCTAssertNil(FuzzyMatcher.score("sir", candidate: "Safari"))
    }

    func testEmptyQueryReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score("", candidate: "Safari"))
    }

    func testEmptyCandidateReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score("a", candidate: ""))
    }

    func testQueryLongerThanCandidateReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score("safaris", candidate: "Safari"))
    }

    // MARK: Ordering

    /// Prefix hits outrank word-start hits, which outrank scattered letters.
    /// Same query and same-length candidates, so only match position varies.
    func testOrderingPrefixBeatsWordStartBeatsScattered() throws {
        let prefix = try XCTUnwrap(FuzzyMatcher.score("sa", candidate: "Sandboxed"))
        let wordStart = try XCTUnwrap(FuzzyMatcher.score("sa", candidate: "Hot Sauce"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score("sa", candidate: "classical"))
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, scattered)
    }

    func testTightRunBeatsGapped() throws {
        let tight = try XCTUnwrap(FuzzyMatcher.score("saf", candidate: "Safari"))
        let gapped = try XCTUnwrap(FuzzyMatcher.score("sfr", candidate: "Safari"))
        XCTAssertGreaterThan(tight, gapped)
    }

    func testShortCandidateWinsNearTies() throws {
        let short = try XCTUnwrap(FuzzyMatcher.score("abc", candidate: "abc"))
        let long = try XCTUnwrap(FuzzyMatcher.score("abc", candidate: "abcdefghijklmnopqrst"))
        XCTAssertGreaterThan(short, long)
    }

    // MARK: Case

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.score("SAFARI", candidate: "Safari"))
        XCTAssertNotNil(FuzzyMatcher.score("safari", candidate: "SAFARI"))
    }

    func testExactCaseScoresAtLeastAsHigh() throws {
        let exact = try XCTUnwrap(FuzzyMatcher.score("Safari", candidate: "Safari"))
        let lowered = try XCTUnwrap(FuzzyMatcher.score("safari", candidate: "Safari"))
        XCTAssertGreaterThanOrEqual(exact, lowered)
    }

    // MARK: Determinism

    func testSameInputGivesSameScore() {
        XCTAssertEqual(
            FuzzyMatcher.score("sfr", candidate: "Safari"),
            FuzzyMatcher.score("sfr", candidate: "Safari")
        )
    }
}
