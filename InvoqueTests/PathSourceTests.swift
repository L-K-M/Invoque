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

    /// Handler-executed formats run on `NSWorkspace.open` with no +x bit —
    /// every extension `isSafeToOpen` blocks must stay unsafe (a literal
    /// list here is the pin; the impl's list could silently shrink). A
    /// `.txt` control stays safe.
    func testHandlerExecutedFormatsAreNotSafeToOpen() throws {
        for ext in ["app", "jar", "jnlp", "workflow", "terminal", "term",
                    "command", "tool", "pkg", "mpkg", "inetloc", "webloc",
                    "url", "fileloc", "ftploc", "afploc", "mailloc", "newsloc",
                    "networkloc", "saver", "prefPane", "menu"] {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("invoque-\(UUID().uuidString).\(ext)")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertFalse(PathSource.isSafeToOpen(file), ext)
        }
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: txt.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: txt) }
        XCTAssertTrue(PathSource.isSafeToOpen(txt))
    }

    /// A bundle declaring `CFBundlePackageType` `APPL` under any extension
    /// is an application — a renamed `.app` must still reveal.
    func testDisguisedApplicationBundleIsNotSafeToOpen() throws {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-\(UUID().uuidString).tool")
        let contents = pkg.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents,
                                                withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """.write(to: contents.appendingPathComponent("Info.plist"),
                  atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pkg) }
        XCTAssertFalse(PathSource.isSafeToOpen(pkg))
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

    /// Hosts are case-insensitive — `file://LOCALHOST/…` is as local as
    /// the lowercase spelling.
    func testLocalhostHostIsCaseInsensitive() {
        XCTAssertEqual(PathSource.resolve("file://LOCALHOST/tmp"),
                       URL(fileURLWithPath: "/tmp"))
    }

    func testFileURLWithRemoteHostIsNotAPath() {
        XCTAssertTrue(source.items(matching: "file://share.example.com/tmp").isEmpty)
    }

    /// A path-shaped string whose tail doesn't exist offers the deepest
    /// ancestor that does — the directory the user is navigating toward.
    /// The row is the ancestor's own, identical to typing its path.
    func testMissingTailOffersNearestAncestor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-ancestor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(source.items(matching: dir.path + "/missing.txt"),
                       source.items(matching: dir.path))
    }

    /// The ancestor walk crosses multiple missing components.
    func testMissingDeepTailOffersNearestAncestor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-ancestor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(source.items(matching: dir.path + "/a/b/c"),
                       source.items(matching: dir.path))
    }

    /// A file component mid-path is still the deepest existing component —
    /// `file.txt/child` offers the file itself, with the same row a direct
    /// `file.txt` query produces (no phantom directory slash on the URL).
    func testFileAncestorOffersTheFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(source.items(matching: file.path + "/child"),
                       source.items(matching: file.path))
    }

    /// `/` and `~` typed directly still produce their rows — the catch-all
    /// suppression applies only to the ancestor fallback, never to an
    /// exact hit.
    func testCatchAllQueriesStillRow() throws {
        let root = try XCTUnwrap(source.items(matching: "/").first)
        XCTAssertEqual(root.action, .openFile(URL(fileURLWithPath: "/")))
        XCTAssertFalse(source.items(matching: "~").isEmpty)
    }

    /// A path-shaped string that doesn't exist emits nothing — `/us` while
    /// typing `/usr` must not flash a phantom row: its only ancestors are
    /// catch-all root-level folders. Same for a missing component straight
    /// under home, and for a `~user` name that can't expand.
    func testMissingPathEmitsNothing() {
        XCTAssertTrue(source.items(matching: "/definitely-not-here-\(UUID().uuidString)").isEmpty)
        XCTAssertTrue(source.items(matching: "/Users/definitely-not-here-\(UUID().uuidString)").isEmpty)
        XCTAssertTrue(source.items(matching: "/Applications/definitely-not-here-\(UUID().uuidString)").isEmpty)
        XCTAssertTrue(source.items(matching: "~/definitely-not-here-\(UUID().uuidString)").isEmpty)
        XCTAssertTrue(source.items(matching: "~definitely-not-a-user-\(UUID().uuidString)/x").isEmpty)
    }

    /// Non-path queries — the overwhelming majority — never reach the
    /// filesystem.
    func testNonPathQueryEmitsNothing() {
        for query in ["safari", "find foo", "make a thing", "1+1", "web/x"] {
            XCTAssertTrue(source.items(matching: query).isEmpty, query)
        }
    }
}
