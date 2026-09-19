import XCTest
@testable import Invoque

final class FileSearchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-filesearch-\(UUID().uuidString)",
                                    isDirectory: true)
        // A visible tree plus the noise the walk must prune: a hidden dir,
        // node_modules, and a package interior.
        try makeFile("notes.txt")
        try makeFile("report-final.pdf")
        try makeFile(".zshrc-local")
        try makeFile("sub/deeper-doc.md")
        try makeFile(".hidden/secret.txt")
        try makeFile("node_modules/left-pad/index.js")
        try makeFile("Fixture.app/Contents/Resources/inside.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func makeFile(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func scannedNames(_ query: String) -> [String] {
        FileSearch.scan(query: query, roots: [root]).map { $0.url.lastPathComponent }
    }

    func testFindsNestedFile() {
        XCTAssertEqual(scannedNames("deeper-doc"), ["deeper-doc.md"])
    }

    /// A hidden *file* in a visible directory is still findable — the walk
    /// prunes hidden directories, not hidden entries.
    func testHiddenFileInVisibleDirMatches() {
        XCTAssertEqual(scannedNames("zshrc-local"), [".zshrc-local"])
    }

    func testHiddenDirectoryIsPruned() {
        XCTAssertTrue(scannedNames("secret").isEmpty)
    }

    func testNodeModulesIsPruned() {
        XCTAssertTrue(scannedNames("index").isEmpty)
    }

    func testPackageContentsAreSkipped() {
        XCTAssertTrue(scannedNames("inside").isEmpty)
    }

    /// The package itself is an entry — pruning hides its interior, not its
    /// name.
    func testPackageItselfMatches() {
        XCTAssertEqual(scannedNames("Fixture"), ["Fixture.app"])
    }

    func testBlankQueryReturnsEmpty() {
        XCTAssertTrue(scannedNames("  ").isEmpty)
    }

    func testCancellationReturnsEmpty() {
        let matches = FileSearch.scan(query: "e", roots: [root]) { true }
        XCTAssertTrue(matches.isEmpty)
    }

    /// `maxVisited` bounds the walk: with the cap at zero nothing is
    /// considered, whatever the tree holds. Restore the default so later
    /// tests in the process aren't capped.
    func testVisitedCapStopsTheWalk() {
        FileSearch.maxVisited = 0
        defer { FileSearch.maxVisited = 500_000 }
        XCTAssertTrue(scannedNames("txt").isEmpty)
    }

    /// A prefix hit beats mid-word fuzzy hits — the sort must rank by
    /// score, not enumeration order. "r-one.txt" matches "r" at position 0;
    /// "report-final.pdf" matches at position 0 too but "deeper-doc.md"
    /// only matches mid-word, so it must never lead.
    func testResultsRankedByScore() throws {
        try makeFile("r-one.txt")
        let names = scannedNames("r")
        XCTAssertGreaterThanOrEqual(names.count, 2)
        XCTAssertEqual(names.first, "r-one.txt")
    }

    func testItemShape() {
        let url = root.appendingPathComponent("notes.txt")
        let item = FileSearch.item(for: url)
        XCTAssertEqual(item.id, Item.fileIDPrefix + url.standardizedFileURL.path)
        XCTAssertEqual(item.title, "notes.txt")
        XCTAssertEqual(item.subtitle, url.deletingLastPathComponent().path)
        XCTAssertEqual(item.icon, .fileURL(url))
        XCTAssertEqual(item.action, .openFile(url))
        XCTAssertEqual(item.matchText, "notes.txt")
    }

    /// Paths under home abbreviate to `~` — the subtitle's compact form.
    func testItemSubtitleAbbreviatesHome() {
        let url = URL(fileURLWithPath:
            NSHomeDirectory() + "/Documents/sheet.numbers")
        XCTAssertEqual(FileSearch.item(for: url).subtitle, "~/Documents")
    }
}
