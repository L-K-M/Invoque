import XCTest
@testable import Invoque

final class GeneratorSourceTests: XCTestCase {

    /// Fully injected source: deterministic UUID, fixed date, fixed roll.
    private func makeSource(uuid: String = "AAAABBBB-CCCC-4DDD-8EEE-FFFF00001111",
                            date: Date = Date(timeIntervalSince1970: 0),
                            roll: @escaping (Int) -> Int = { _ in 1 }) -> GeneratorSource {
        GeneratorSource(makeUUID: { uuid }, now: { date }, roll: roll)
    }

    // MARK: uuid

    func testUUIDKeywordMintsAndCopies() throws {
        let item = try XCTUnwrap(
            makeSource().items(matching: "uuid").first)
        XCTAssertEqual(item.id, "gen:uuid")
        XCTAssertEqual(item.title, "AAAABBBB-CCCC-4DDD-8EEE-FFFF00001111")
        XCTAssertEqual(item.action, .copyText("AAAABBBB-CCCC-4DDD-8EEE-FFFF00001111"))
    }

    func testGUIDAliasResolves() throws {
        let item = try XCTUnwrap(
            makeSource().items(matching: "GUID").first)
        XCTAssertEqual(item.id, "gen:uuid")
    }

    /// The value is fresh per call — the mint runs on every query.
    func testUUIDIsFreshPerQuery() {
        var minted = 0
        let source = GeneratorSource(
            makeUUID: { minted += 1; return "uuid-\(minted)" },
            now: { Date() }, roll: { _ in 1 })
        XCTAssertEqual(source.items(matching: "uuid").first?.title, "uuid-1")
        XCTAssertEqual(source.items(matching: "uuid").first?.title, "uuid-2")
    }

    // MARK: now

    func testNowEmitsISO8601UTC() throws {
        let item = try XCTUnwrap(
            makeSource().items(matching: "now").first)
        XCTAssertEqual(item.id, "gen:now")
        // The epoch — a date whose ISO form needs no derivation.
        XCTAssertEqual(item.title, "1970-01-01T00:00:00Z")
        XCTAssertEqual(item.action, .copyText("1970-01-01T00:00:00Z"))
    }

    // MARK: flip

    func testFlipLandsHeadsOrTails() throws {
        let heads = try XCTUnwrap(
            makeSource(roll: { _ in 1 }).items(matching: "flip").first)
        XCTAssertEqual(heads.title, "Heads")
        let tails = try XCTUnwrap(
            makeSource(roll: { _ in 2 }).items(matching: "flip coin").first)
        XCTAssertEqual(tails.title, "Tails")
        XCTAssertEqual(tails.action, .copyText("Tails"))
    }

    // MARK: roll

    func testRollKeywordDefaultsToD20() throws {
        let item = try XCTUnwrap(
            makeSource(roll: { _ in 17 }).items(matching: "roll").first)
        XCTAssertEqual(item.subtitle, "Roll d20 — ⏎ copies")
        XCTAssertEqual(item.title, "17")
        XCTAssertEqual(item.action, .copyText("17"))
    }

    func testBareDiceNotationRolls() throws {
        let item = try XCTUnwrap(
            makeSource(roll: { _ in 3 }).items(matching: "d12").first)
        XCTAssertEqual(item.subtitle, "Roll d12 — ⏎ copies")
        XCTAssertEqual(item.title, "3")
    }

    func testRollWithSidesParses() throws {
        let item = try XCTUnwrap(
            makeSource(roll: { _ in 6 }).items(matching: "roll d6").first)
        XCTAssertEqual(item.subtitle, "Roll d6 — ⏎ copies")
    }

    func testDiceParsingBoundaries() {
        XCTAssertEqual(GeneratorSource.parseDiceKeyword("roll"), 20)
        XCTAssertEqual(GeneratorSource.parseDiceKeyword("roll d2"), 2)
        XCTAssertEqual(GeneratorSource.parseDiceKeyword("d100"), 100)
        // A one-sided die is a constant, not a roll; garbage declines.
        XCTAssertNil(GeneratorSource.parseDiceKeyword("d1"))
        XCTAssertNil(GeneratorSource.parseDiceKeyword("d0"))
        XCTAssertNil(GeneratorSource.parseDiceKeyword("d"))
        XCTAssertNil(GeneratorSource.parseDiceKeyword("roll d"))
        XCTAssertNil(GeneratorSource.parseDiceKeyword("roll 20"))
        XCTAssertNil(GeneratorSource.parseDiceKeyword("xd20"))
        // Unicode digit forms decline at the parse, not in Int().
        XCTAssertNil(GeneratorSource.parseDiceKeyword("d\u{0668}\u{0660}"))
    }

    // MARK: Exact-match discipline

    /// Generators never fire on partials or fuzzy input — typing toward
    /// an app named "Roller" or "Now Playing" must not trip them.
    func testPartialsAndFuzzyInputDecline() {
        let source = makeSource()
        XCTAssertTrue(source.items(matching: "uui").isEmpty)
        XCTAssertTrue(source.items(matching: "no").isEmpty)
        XCTAssertTrue(source.items(matching: "fli").isEmpty)
        XCTAssertTrue(source.items(matching: "rol").isEmpty)
        XCTAssertTrue(source.items(matching: "uuid now").isEmpty)
        XCTAssertTrue(source.items(matching: "").isEmpty)
    }

    /// Surrounding whitespace is fine — the query trims.
    func testSurroundingWhitespaceTrims() throws {
        let item = try XCTUnwrap(
            makeSource().items(matching: "  uuid  ").first)
        XCTAssertEqual(item.id, "gen:uuid")
    }
}
