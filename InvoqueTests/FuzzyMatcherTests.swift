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

    // MARK: Tiers

    /// `match` classifies the hit: an exact prefix, then a contiguous
    /// substring elsewhere, then a scattered subsequence. `nil` is no
    /// match at all — same contract as `score`.
    func testMatchClassifiesPrefixInfixFuzzy() throws {
        XCTAssertEqual(FuzzyMatcher.match("saf", candidate: "Safari")?.tier, .prefix)
        XCTAssertEqual(FuzzyMatcher.match("saf", candidate: "Asafari")?.tier, .infix)
        XCTAssertEqual(FuzzyMatcher.match("sfr", candidate: "Safari")?.tier, .fuzzy)
        XCTAssertNil(FuzzyMatcher.match("xyz", candidate: "Safari"))
    }

    /// The infix probe must not rely on the greedy alignment — the leftmost
    /// per-character walk aligns "saf" at 0,1,4 in "sasaf" and would miss
    /// the contiguous hit sitting at index 2.
    func testInfixDetectedPastGreedyAlignment() throws {
        XCTAssertEqual(FuzzyMatcher.match("saf", candidate: "sasaf")?.tier, .infix)
    }

    /// A prefix is also a contiguous substring — the prefix tier wins the
    /// tiebreak order.
    func testPrefixDoesNotFallThroughToInfix() throws {
        XCTAssertEqual(FuzzyMatcher.match("saf", candidate: "SafxSafay")?.tier, .prefix)
    }

    func testMatchScoreAgreesWithScore() {
        XCTAssertEqual(FuzzyMatcher.match("saf", candidate: "Safari")?.score,
                       FuzzyMatcher.score("saf", candidate: "Safari"))
        XCTAssertEqual(FuzzyMatcher.match("sfr", candidate: "Safari")?.score,
                       FuzzyMatcher.score("sfr", candidate: "Safari"))
    }

    /// The title-visible probe shares `match`'s normalization: a
    /// contiguous hit is exactly a match whose tier is prefix or infix.
    func testContainsMirrorsMatchNormalization() {
        for (query, candidate) in [("saf", "Safari"),
                                   ("rowser", "Zen Zen Browser"),
                                   ("sfr", "Safari"),
                                   ("xyz", "Safari")] {
            let tier = FuzzyMatcher.match(query, candidate: candidate)?.tier
            XCTAssertEqual(FuzzyMatcher.contains(query, in: candidate),
                           tier == .prefix || tier == .infix,
                           "\(query) in \(candidate)")
        }
        // Nothing beyond lowercasing is folded — "cafe" isn't contiguous
        // in "Café Notes" (é ≠ e), so the probe says false while the
        // matcher still finds the scattered fallback (…e in "Notes").
        XCTAssertFalse(FuzzyMatcher.contains("cafe", in: "Café Notes"))
        XCTAssertEqual(FuzzyMatcher.match("cafe", candidate: "Café Notes")?
            .tier, .fuzzy)
        XCTAssertFalse(FuzzyMatcher.contains("", in: "Safari"))
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
