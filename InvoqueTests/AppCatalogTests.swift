import XCTest
@testable import Invoque

final class AppCatalogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCatalogTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    private func entry(name: String = "Test App",
                       path: String = "/Applications/Test.app",
                       bundleID: String? = "com.test.app",
                       fileName: String = "Test") -> AppEntry {
        AppEntry(name: name, path: path, bundleID: bundleID, fileName: fileName)
    }

    private var catalog: [AppEntry] {
        [
            entry(),
            entry(name: "Other App", path: "/Applications/Other.app",
                  bundleID: "com.test.other", fileName: "Other"),
        ]
    }

    /// A real on-disk `.app` directory plus the catalog entry that admits it
    /// — `resolve` confines path targets to catalog members, and standardizes
    /// the input (resolving `/var` → `/private/var`), so the fixture entry's
    /// path must be the resolved form too. No `isDirectory:` on the URL: the
    /// trailing slash it adds would leak into `realPath`.
    private func makeBundle(named name: String) throws -> (url: URL, entry: AppEntry) {
        let url = tempDir.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let realPath = url.resolvingSymlinksInPath().path
        return (url, entry(path: realPath))
    }

    // MARK: Path targets

    /// `~/Applications` is the catalog's first scan directory, so a `~`
    /// path target must expand before the .app/existence/membership checks —
    /// `URL(fileURLWithPath:)` treats `~` as a literal component.
    func testResolveByTildePath() throws {
        let dirName = "AppCatalogTests.\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(dirName, isDirectory: true)
        let app = dir.appendingPathComponent("Home App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let realPath = app.resolvingSymlinksInPath().path
        let e = entry(name: "Home App", path: realPath, fileName: "Home App")
        XCTAssertEqual(AppCatalog.resolve("~/\(dirName)/Home App.app", in: [e])?.path,
                       realPath)
    }

    /// Tilde expansion adds reachability, not privilege: an existing `~` path
    /// outside the catalog still resolves to nil.
    func testResolveTildePathStillConfinedToCatalog() throws {
        let dirName = "AppCatalogTests.\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(dirName, isDirectory: true)
        let app = dir.appendingPathComponent("Stray.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(AppCatalog.resolve("~/\(dirName)/Stray.app", in: catalog))
        XCTAssertNil(AppCatalog.resolve("~/\(dirName)/Missing.app", in: catalog))
    }

    // MARK: Name / bundle-id matching

    func testResolveByExactName() {
        XCTAssertEqual(AppCatalog.resolve("Test App", in: catalog)?.path,
                       "/Applications/Test.app")
    }

    func testResolveByNameIsCaseInsensitive() {
        XCTAssertEqual(AppCatalog.resolve("test app", in: catalog)?.path,
                       "/Applications/Test.app")
    }

    func testResolveByBundleID() {
        XCTAssertEqual(AppCatalog.resolve("com.test.other", in: catalog)?.path,
                       "/Applications/Other.app")
    }

    func testResolveByBundleIDIsCaseInsensitive() {
        XCTAssertEqual(AppCatalog.resolve("COM.TEST.OTHER", in: catalog)?.path,
                       "/Applications/Other.app")
    }

    func testResolveByFileName() {
        let apps = [entry(name: "Localized Name", fileName: "Test")]
        XCTAssertEqual(AppCatalog.resolve("Test", in: apps)?.path,
                       "/Applications/Test.app")
    }

    func testResolveFallsBackToPathWhenBundleIDMissing() {
        let apps = [entry(bundleID: nil)]
        // A missing bundle id still resolves by name — it just can't be
        // matched *as* a bundle id.
        XCTAssertEqual(AppCatalog.resolve("Test App", in: apps)?.path,
                       "/Applications/Test.app")
        XCTAssertNil(AppCatalog.resolve("com.test.app", in: apps))
    }

    // MARK: Strictness

    func testResolveRejectsPartialName() {
        // Launching is a side effect — a fuzzy match that opens the wrong
        // app is worse than a clean miss the script can report. ("Test"
        // alone is *not* a partial: it's Test.app's exact fileName.)
        XCTAssertNil(AppCatalog.resolve("Test A", in: catalog))
        XCTAssertNil(AppCatalog.resolve("Oth", in: catalog))
    }

    func testResolveRejectsUnknownName() {
        XCTAssertNil(AppCatalog.resolve("Not Installed", in: catalog))
    }

    func testResolveRejectsEmptyAndWhitespace() {
        XCTAssertNil(AppCatalog.resolve("", in: catalog))
        XCTAssertNil(AppCatalog.resolve("   ", in: catalog))
    }

    // MARK: Path targets

    func testResolveByExistingPath() throws {
        let bundle = try makeBundle(named: "DiskBound")
        XCTAssertEqual(AppCatalog.resolve(bundle.url.path, in: [bundle.entry])?.path,
                       bundle.entry.path)
    }

    func testResolveByFileURL() throws {
        let bundle = try makeBundle(named: "URLBound")
        XCTAssertEqual(AppCatalog.resolve(bundle.url.absoluteString, in: [bundle.entry])?.path,
                       bundle.entry.path)
        // A directory file:// URL carries a trailing slash — still resolves.
        XCTAssertEqual(AppCatalog.resolve(bundle.url.absoluteString + "/", in: [bundle.entry])?.path,
                       bundle.entry.path)
    }

    func testResolveByFileURLWithRawSpaces() throws {
        // URL(string:) refuses unencoded spaces, which app paths routinely
        // contain — the fallback treats the remainder as a plain path.
        let bundle = try makeBundle(named: "Spaced Name")
        let rawURL = "file://\(bundle.url.path)"
        XCTAssertEqual(AppCatalog.resolve(rawURL, in: [bundle.entry])?.path,
                       bundle.entry.path)
    }

    func testResolveByPathRequiresAppExtension() throws {
        let notApp = tempDir.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: notApp, withIntermediateDirectories: true)
        let realPath = notApp.resolvingSymlinksInPath().path
        XCTAssertNil(AppCatalog.resolve(notApp.path, in: [entry(path: realPath)]))
    }

    func testResolveByPathRequiresExistence() {
        XCTAssertNil(AppCatalog.resolve("/Applications/Ghost.app",
                                        in: [entry(path: "/Applications/Ghost.app")]))
    }

    func testResolveRejectsPathOutsideCatalog() throws {
        // The `apps` permission scopes launches to the apps the launcher
        // itself searches — an existing .app outside the catalog (a
        // quarantined download, a mounted DMG) must not resolve.
        let bundle = try makeBundle(named: "OffCatalog")
        XCTAssertNil(AppCatalog.resolve(bundle.url.path, in: catalog))
    }

    // MARK: Strictness

    func testResolveNeverMatchesEmptyBundleID() {
        // A malformed bundle with "" as its id must not answer a bundle-id
        // query — and the query itself can never be "" (guarded above).
        XCTAssertNil(AppCatalog.resolve("com.test.app", in: [entry(bundleID: "")]))
    }

    // MARK: Cryptex graft

    /// End-to-end pin for the cryptex fix: Safari's catalog entry records
    /// its real (cryptex) path, and a literal `/Applications/Safari.app`
    /// target — the spelling scripts pass to `apps.launch` — must still
    /// resolve to it. Works because `resolve` standardizes targets with
    /// `resolvingSymlinksInPath`, which crosses the graft to the same
    /// canonical path the scan recorded.
    func testResolveMatchesGraftedApplicationsSpelling() throws {
        let graftedPath = "/Applications/Safari.app"
        let cryptexPath =
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cryptexPath),
                          "requires the Safari cryptex")
        let safari = entry(name: "Safari", path: cryptexPath,
                           bundleID: "com.apple.Safari", fileName: "Safari")
        XCTAssertEqual(AppCatalog.resolve(graftedPath, in: [safari])?.path,
                       cryptexPath)
    }

    /// The fix itself: the catalog must walk the App cryptex — Safari
    /// lives there since Ventura and is invisible to `/Applications`
    /// enumeration. It must also scan last: first-directory-wins dedup
    /// means any bundle found in an earlier directory — a user-installed
    /// copy, say — shadows the cryptex original only while the cryptex
    /// root trails. Static data, so it runs on every macOS version
    /// without skips.
    func testSearchDirectoriesEndsWithAppCryptex() {
        XCTAssertEqual(
            AppCatalog.searchDirectories.last?.path,
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications")
    }

    // MARK: Precedence

    func testResolvePrefersPathOverName() throws {
        // The decoy's *name* is the literal path target — if name matching
        // ever ran first it would win, resolving to the wrong bundle.
        let bundle = try makeBundle(named: "Real")
        let decoy = entry(name: bundle.url.path, path: "/Applications/Decoy.app",
                          bundleID: "com.decoy", fileName: "Decoy")
        XCTAssertEqual(AppCatalog.resolve(bundle.url.path, in: [bundle.entry, decoy])?.path,
                       bundle.entry.path)
    }
}
