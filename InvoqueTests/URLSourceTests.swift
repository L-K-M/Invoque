import XCTest
@testable import Invoque

final class URLSourceTests: XCTestCase {

    private let source = URLSource()

    // MARK: Resolution

    /// A pasted http(s) URL opens itself — ⏎ must not hand the address to
    /// a search engine.
    func testDirectURLOpens() throws {
        let items = source.items(matching: "https://example.com/release?v=2")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, "url:https://example.com/release?v=2")
        XCTAssertEqual(item.action, .openURL(
            URL(string: "https://example.com/release?v=2")!))
        XCTAssertTrue(item.subtitle.hasPrefix("Open the URL"))
    }

    func testHTTPIsAcceptedToo() throws {
        let item = try XCTUnwrap(
            source.items(matching: "http://example.com").first)
        XCTAssertEqual(item.action, .openURL(
            URL(string: "http://example.com")!))
    }

    /// Scheme comparison is case-insensitive per RFC 3986 — browsers paste
    /// mixed case rarely, but a typed `HTTPS://` must still resolve.
    func testUppercaseSchemeResolves() throws {
        let item = try XCTUnwrap(
            source.items(matching: "HTTPS://example.com").first)
        XCTAssertEqual(item.action, .openURL(
            URL(string: "HTTPS://example.com")!))
    }

    func testSurroundingWhitespaceTrims() throws {
        let item = try XCTUnwrap(
            source.items(matching: "  https://example.com\n").first)
        XCTAssertEqual(item.action, .openURL(
            URL(string: "https://example.com")!))
    }

    // MARK: Non-URLs

    /// No host — not an address, and `URL(string:)` can't anchor one.
    func testSchemeAloneEmitsNothing() {
        XCTAssertTrue(source.items(matching: "https://").isEmpty)
        XCTAssertTrue(source.items(matching: "http://").isEmpty)
    }

    /// Other schemes are not this source's business — `file:` belongs to
    /// `PathSource`, `mailto:` to nobody.
    func testNonWebSchemeEmitsNothing() {
        XCTAssertTrue(source.items(matching: "mailto:someone@example.com").isEmpty)
        XCTAssertTrue(source.items(matching: "file:///tmp").isEmpty)
        XCTAssertTrue(source.items(matching: "invoque://panel").isEmpty)
    }

    /// A plain word has no scheme — that's a search, not an address.
    func testPlainWordIsNotAURL() {
        XCTAssertTrue(source.items(matching: "safari").isEmpty)
        XCTAssertTrue(source.items(matching: "example").isEmpty)
    }

    /// A raw space means prose, not a pasted address — browsers
    /// percent-encode spaces, so whitespace disqualifies the query even
    /// though Foundation's lenient `URL(string:)` parser would accept it.
    func testQueryWithUnencodedSpaceEmitsNothing() {
        XCTAssertTrue(
            source.items(matching: "https://example.com/a b").isEmpty)
    }

    /// A query that merely *contains* a URL is still a search — only the
    /// whole query being the address is direct intent.
    func testURLInsideLongerQueryEmitsNothing() {
        XCTAssertTrue(
            source.items(matching: "see https://example.com/docs").isEmpty)
    }
}
