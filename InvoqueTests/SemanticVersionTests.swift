import XCTest
@testable import Invoque

final class SemanticVersionTests: XCTestCase {

    func testParsesAndStripsLeadingV() {
        XCTAssertEqual(SemanticVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(SemanticVersion("1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(SemanticVersion("  V2.0  ")?.components, [2, 0])
    }

    func testRejectsGarbage() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion("1.x.3"))
        XCTAssertNil(SemanticVersion("v"))
    }

    func testComparisonIsNumericNotLexical() {
        XCTAssertTrue(SemanticVersion("1.10.0")! > SemanticVersion("1.9.0")!)   // 10 > 9
        XCTAssertTrue(SemanticVersion("2.0.0")! > SemanticVersion("1.999.0")!)
    }

    func testZeroPaddingEquivalence() {
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertFalse(SemanticVersion("1.2")! < SemanticVersion("1.2.0")!)
        XCTAssertFalse(SemanticVersion("1.2.0")! < SemanticVersion("1.2")!)
    }

    func testPrereleaseSortsBelowFinal() {
        XCTAssertTrue(SemanticVersion("1.2.0-beta.1")! < SemanticVersion("1.2.0")!)
        XCTAssertTrue(SemanticVersion("1.2.0")! > SemanticVersion("1.2.0-rc.1")!)
        XCTAssertTrue(SemanticVersion("1.2.0-beta")! > SemanticVersion("1.1.9")!)   // numbers win first
    }

    /// Semver: numeric pre-release identifiers compare numerically, not
    /// lexically — "beta.10" is newer than "beta.2".
    func testPrereleaseNumericIdentifiersCompareNumerically() {
        XCTAssertTrue(SemanticVersion("1.2.0-beta.10")! > SemanticVersion("1.2.0-beta.2")!)
        XCTAssertTrue(SemanticVersion("1.2.0-rc.10")! > SemanticVersion("1.2.0-rc.9")!)
        // Numeric identifiers sort before alphanumeric ones per semver.
        XCTAssertTrue(SemanticVersion("1.2.0-1")! < SemanticVersion("1.2.0-alpha")!)
    }

    /// Semver §11: a numeric identifier always ranks below an alphanumeric
    /// one — even when the alphanumeric starts with a digit or a hyphen.
    /// A mixed-pair lexical fallback breaks strict weak ordering
    /// (beta.2 < beta.10 < beta.1a < beta.2 — a cycle).
    func testPrereleaseMixedIdentifiersKeepStrictOrdering() {
        let beta2 = SemanticVersion("1.0.0-beta.2")!
        let beta10 = SemanticVersion("1.0.0-beta.10")!
        let beta1a = SemanticVersion("1.0.0-beta.1a")!
        XCTAssertTrue(beta2 < beta10)   // numeric < numeric
        XCTAssertTrue(beta2 < beta1a)   // numeric < alphanumeric
        XCTAssertTrue(beta10 < beta1a)
        // No cycle: a < b and b < c implies a < c.
        XCTAssertTrue(beta2 < beta1a && beta10 < beta1a)
        // A hyphen-led identifier is alphanumeric — still outranks numeric.
        XCTAssertTrue(SemanticVersion("1.0.0-beta.1")! < SemanticVersion("1.0.0-beta.-rc")!)
        // Prefix rule unchanged: shorter identifier set ranks first.
        XCTAssertTrue(SemanticVersion("1.0.0-beta")! < SemanticVersion("1.0.0-beta.1")!)
    }

    /// Numeric identifiers longer than `Int` can hold must still order
    /// numerically — a lexical fallback on the overflow pair re-opens the
    /// strict-weak-ordering cycle ("3" < "19" < "20000000000000000000" < "3").
    func testPrereleaseOverflowLengthNumericsOrderByMagnitude() {
        let huge = SemanticVersion("1.0.0-a.20000000000000000000")!
        XCTAssertTrue(SemanticVersion("1.0.0-a.3")! < SemanticVersion("1.0.0-a.19")!)
        XCTAssertTrue(SemanticVersion("1.0.0-a.19")! < huge)
        XCTAssertFalse(huge < SemanticVersion("1.0.0-a.3")!)
        // Equal-length digit strings order like their digits.
        XCTAssertTrue(SemanticVersion("1.0.0-a.10000000000000000000")! < huge)
    }

    func testNewerThanCurrentDetection() {
        let current = SemanticVersion("1.0")!
        XCTAssertTrue(SemanticVersion("1.0.1")! > current)
        XCTAssertTrue(SemanticVersion("1.1")! > current)
        XCTAssertFalse(SemanticVersion("1.0")! > current)
        XCTAssertFalse(SemanticVersion("0.9")! > current)
    }

    func testIgnoresBuildMetadata() {
        XCTAssertEqual(SemanticVersion("1.2.3+build.99"), SemanticVersion("1.2.3"))
    }
}
