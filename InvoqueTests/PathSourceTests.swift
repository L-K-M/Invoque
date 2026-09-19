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

    /// A pasted `.app` path must reveal, never launch — packages are
    /// directories, so they'd otherwise slip past the file check.
    func testAppBundleRevealsInsteadOfLaunching() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("Invoque-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let item = try XCTUnwrap(source.items(matching: app.path).first)
        XCTAssertEqual(item.action, .revealInFinder(app))
        XCTAssertTrue(item.subtitle.hasPrefix("Reveal in Finder"))
    }

    /// `URL(string:)` rejects unencoded characters — a pasted file URL
    /// with a literal space must still resolve to the same row the typed
    /// path produces.
    func testFileURLWithUnencodedSpaceResolves() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque dir \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(source.items(matching: "file://\(dir.path)"),
                       source.items(matching: dir.path))
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
