import XCTest
@testable import Invoque

final class PathSourceTests: XCTestCase {

    private let source = PathSource()

    // MARK: Action by kind

    /// A pasted directory opens — its `path:` row carries `.openFile` and
    /// the subtitle names the verb so ⏎'s behavior is visible up front.
    func testDirectoryPathOpens() throws {
        let items = source.items(matching: "/tmp")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, "path:/tmp")
        XCTAssertEqual(item.action, .openFile(URL(fileURLWithPath: "/tmp")))
        XCTAssertTrue(item.subtitle.hasPrefix("Open"))
    }

    /// A pasted file reveals in Finder — running it is never the default.
    func testFilePathReveals() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-path-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }

        let item = try XCTUnwrap(source.items(matching: file.path).first)
        XCTAssertEqual(item.action, .revealInFinder(file))
        XCTAssertEqual(item.title, file.lastPathComponent)
        XCTAssertTrue(item.subtitle.hasPrefix("Reveal in Finder"))
    }

    // MARK: Query shapes

    func testTildeResolvesHome() throws {
        let item = try XCTUnwrap(source.items(matching: "~").first)
        let home = ("~" as NSString).expandingTildeInPath
        XCTAssertEqual(item.action, .openFile(URL(fileURLWithPath: home)))
    }

    func testFileURLResolves() throws {
        let items = source.items(matching: "file:///tmp")
        XCTAssertEqual(items.first?.action,
                       .openFile(URL(fileURLWithPath: "/tmp")))
    }

    /// `file:///tmp` and a typed `/tmp` name the same directory — both query
    /// forms must produce identical rows (same id, same action URL).
    func testFileURLMatchesTypedPath() throws {
        XCTAssertEqual(source.items(matching: "file:///tmp"),
                       source.items(matching: "/tmp"))
    }

    /// Bare `file://` carries no path — it must not resolve to the cwd.
    func testBareFileSchemeEmitsNothing() {
        XCTAssertTrue(source.items(matching: "file://").isEmpty)
    }

    func testFileURLWithRemoteHostIsNotAPath() {
        XCTAssertTrue(source.items(matching: "file://share.example.com/tmp").isEmpty)
    }

    /// A path-shaped string that doesn't exist emits nothing — `/us` while
    /// typing `/usr` must not flash a phantom row.
    func testMissingPathEmitsNothing() {
        XCTAssertTrue(source.items(matching: "/definitely-not-here-\(UUID().uuidString)").isEmpty)
    }

    /// Non-path queries — the overwhelming majority — never reach the
    /// filesystem.
    func testNonPathQueryEmitsNothing() {
        for query in ["safari", "find foo", "make a thing", "1+1", "web/x"] {
            XCTAssertTrue(source.items(matching: query).isEmpty, query)
        }
    }
}
