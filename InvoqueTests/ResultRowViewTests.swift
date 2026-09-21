import XCTest
@testable import Invoque

/// The pure title-splitting logic behind the matched-text highlight —
/// the render itself needs a GUI session.
final class ResultRowViewTests: XCTestCase {

    func testSegmentsAroundPrefixHit() {
        let segments = ResultRowView.highlightSegments(of: "saf", in: "Safari")
        XCTAssertEqual(segments?.before, "")
        XCTAssertEqual(segments?.matched, "Saf")
        XCTAssertEqual(segments?.after, "ari")
    }

    func testSegmentsAroundInfixHit() {
        let segments = ResultRowView.highlightSegments(of: "fox", in: "Firefox")
        XCTAssertEqual(segments?.before, "Fire")
        XCTAssertEqual(segments?.matched, "fox")
        XCTAssertEqual(segments?.after, "")
    }

    func testMatchIsCaseInsensitive() {
        // The typed query is lowercase, the title caps the hit — the
        // matched segment keeps the title's own characters.
        let segments = ResultRowView.highlightSegments(of: "term", in: " iTerm ")
        XCTAssertEqual(segments?.before, " i")
        XCTAssertEqual(segments?.matched, "Term")
        XCTAssertEqual(segments?.after, " ")
    }

    /// A fuzzy-tier match has no contiguous occurrence — nothing
    /// highlights rather than approximating scattered spans.
    func testScatteredMatchYieldsNil() {
        XCTAssertNil(ResultRowView.highlightSegments(of: "sfr", in: "Safari"))
    }

    func testNoMatchYieldsNil() {
        XCTAssertNil(ResultRowView.highlightSegments(of: "zzz", in: "Safari"))
    }

    func testNilOrBlankQueryYieldsNil() {
        XCTAssertNil(ResultRowView.highlightSegments(of: nil, in: "Safari"))
        XCTAssertNil(ResultRowView.highlightSegments(of: "", in: "Safari"))
    }

    /// Only the first occurrence marks — "banana" for "a" highlights the
    /// first "a", never both.
    func testFirstOccurrenceWins() {
        let segments = ResultRowView.highlightSegments(of: "a", in: "banana")
        XCTAssertEqual(segments?.before, "b")
        XCTAssertEqual(segments?.matched, "a")
        XCTAssertEqual(segments?.after, "nana")
    }
}
