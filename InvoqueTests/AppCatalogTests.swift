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

    /// A real on-disk `.app` directory — `resolve` takes a path target
    /// literally only when the bundle actually exists.
    private func makeBundle(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        XCTAssertEqual(AppCatalog.resolve(bundle.path, in: []), bundle)
    }

    func testResolveByFileURL() throws {
        let bundle = try makeBundle(named: "URLBound")
        XCTAssertEqual(AppCatalog.resolve(bundle.absoluteString, in: [])?.path,
                       bundle.path)
    }

    func testResolveByPathRequiresAppExtension() throws {
        let notApp = tempDir.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: notApp, withIntermediateDirectories: true)
        XCTAssertNil(AppCatalog.resolve(notApp.path, in: []))
    }

    func testResolveByPathRequiresExistence() {
        XCTAssertNil(AppCatalog.resolve("/Applications/Ghost.app", in: []))
    }

    // MARK: Precedence

    func testResolvePrefersPathOverName() throws {
        // A target that looks like a path is taken literally — it never
        // falls through to a name that happens to contain slashes.
        let bundle = try makeBundle(named: "Real")
        let decoy = entry(name: "Decoy", path: bundle.path,
                          bundleID: "com.decoy", fileName: "Decoy")
        XCTAssertEqual(AppCatalog.resolve(bundle.path, in: [decoy]), bundle)
    }
}
