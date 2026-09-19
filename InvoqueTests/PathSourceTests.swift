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
        // The canonical file URL gains a trailing slash for a directory.
        XCTAssertEqual(item.action,
                       .revealInFinder(URL(fileURLWithPath: app.path)))
        XCTAssertTrue(item.subtitle.hasPrefix("Reveal in Finder"))
    }

    /// A document package is a directory but opens in its editor — a
    /// pasted `.xcodeproj` opens in Xcode rather than revealing.
    func testNonAppPackageOpens() throws {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("Invoque-\(UUID().uuidString).xcodeproj")
        try FileManager.default.createDirectory(at: pkg,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: pkg) }
        let item = try XCTUnwrap(source.items(matching: pkg.path).first)
        XCTAssertEqual(item.action, .openFile(URL(fileURLWithPath: pkg.path)))
    }

    /// An executable file carries the +x bit — pasted, it must reveal,
    /// never run. (The row is a file, so it reveals anyway; this pins
    /// `isSafeToOpen` so the ⌘⏎ inverse can't open it either.)
    func testExecutableFileIsNotSafeToOpen() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-\(UUID().uuidString).sh")
        FileManager.default.createFile(atPath: script.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertFalse(PathSource.isSafeToOpen(script))
        XCTAssertTrue(PathSource.isSafeToOpen(
            FileManager.default.temporaryDirectory))
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

    /// `?`/`#` are legal filename characters — a `file://` URL containing
    /// them must not be parsed as query/fragment and truncated.
    func testFileURLKeepsQueryAndFragmentLiterally() {
        XCTAssertEqual(PathSource.resolve("file:///tmp/a?b"),
                       URL(fileURLWithPath: "/tmp/a?b"))
        XCTAssertEqual(PathSource.resolve("file:///tmp/a#b"),
                       URL(fileURLWithPath: "/tmp/a#b"))
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
