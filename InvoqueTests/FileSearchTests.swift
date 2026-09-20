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

    /// Every unconditional entry in `skippedDirectoryNames` must prune its
    /// contents — keeps the list honest as it grows.
    func testAllSkippedDirectoryNamesPruneContents() throws {
        for name in FileSearch.skippedDirectoryNames {
            try makeFile("\(name)/probe-\(name).txt")
            XCTAssertTrue(scannedNames("probe-\(name)").isEmpty,
                          "expected \(name) contents to be pruned")
        }
    }

    /// The comparison lowercases: a `Pods` dir prunes exactly like `pods`.
    func testSkippedNamesAreCaseInsensitive() throws {
        try makeFile("Pods/podfile-case-probe.txt")
        XCTAssertTrue(scannedNames("podfile-case-probe").isEmpty)
    }

    /// `build`/`dist`/`target` prune only beside a project manifest —
    /// generated output skips, a hand-made folder's files stay findable.
    func testProjectScopedDirPrunedBesideManifest() throws {
        try makeFile("proj/package.json")
        try makeFile("proj/build/scoped-probe.txt")
        XCTAssertTrue(scannedNames("scoped-probe").isEmpty)
    }

    /// The manifest list covers C-family builds too — CMake's `build/`
    /// convention is the most common producer of generic build dirs.
    func testProjectScopedDirPrunedBesideCMake() throws {
        try makeFile("proj/CMakeLists.txt")
        try makeFile("proj/build/cmake-probe.txt")
        XCTAssertTrue(scannedNames("cmake-probe").isEmpty)
        // The pruned dir's own name must not match either — the walk
        // continues before scoring (see FileSearch's doc comment).
        XCTAssertTrue(scannedNames("build").isEmpty)
    }

    func testProjectScopedDirWithoutManifestIsSearched() throws {
        try makeFile("docs/build/plain-probe.txt")
        XCTAssertEqual(scannedNames("plain-probe"), ["plain-probe.txt"])
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

    /// Exclusion runs inside the walk, before the result cap: with one
    /// more match than the cap, dropping the top-ranked file backfills
    /// the slot — a blocked file leaves no hole in the list.
    func testExclusionBackfillsBeyondTheCap() throws {
        for index in 0...SearchModel.maxResults {
            try makeFile(String(format: "fill-%02d.txt", index))
        }
        // Equal-length prefix matches sort by path — fill-00 leads,
        // fill-50 sits just past the cap.
        let excludedID = Item.fileIDPrefix
            + root.appendingPathComponent("fill-00.txt")
                .standardizedFileURL.path
        let matches = FileSearch.scan(query: "fill", roots: [root],
                                      isExcluded: { $0 == excludedID })
        XCTAssertEqual(matches.count, SearchModel.maxResults)
        let names = matches.map { $0.url.lastPathComponent }
        XCTAssertFalse(names.contains("fill-00.txt"))
        XCTAssertTrue(names.contains("fill-50.txt"),
                      "the match past the cap must backfill the hole")
    }

    /// `maxVisited` bounds the walk: with the cap at zero nothing is
    /// considered, whatever the tree holds. Restore the default so later
    /// tests in the process aren't capped.
    func testVisitedCapStopsTheWalk() {
        let defaultMaxVisited = FileSearch.maxVisited
        FileSearch.maxVisited = 0
        defer { FileSearch.maxVisited = defaultMaxVisited }
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

    /// Same ordering as the launcher search: prefix tier beats infix beats
    /// fuzzy, then the shorter filename. "ab" hits nothing in the fixture,
    /// so the list is exactly the three planted files.
    func testRankedByTierThenLength() throws {
        try makeFile("abx.txt")      // prefix — 7 chars
        try makeFile("xab.txt")      // infix — 7 chars
        try makeFile("axxbxx.txt")   // fuzzy only — 10 chars
        XCTAssertEqual(scannedNames("ab"),
                       ["abx.txt", "xab.txt", "axxbxx.txt"])
    }

    /// The discriminating case for tier-over-score ordering: "a b.txt"
    /// out-scores the infix on raw alignment (two word-start bonuses) but
    /// only fuzzy-matches — the tier key still puts the infix first.
    func testInfixBeatsHigherScoredFuzzy() throws {
        try makeFile("a b.txt")        // fuzzy — two word-start bonuses
        try makeFile("wxyzabq.txt")    // infix — contiguous but gapped
        // Guard the premise: the fuzzy hit really does score higher.
        XCTAssertGreaterThan(
            FuzzyMatcher.score("ab", candidate: "a b.txt") ?? 0,
            FuzzyMatcher.score("ab", candidate: "wxyzabq.txt") ?? 0)
        XCTAssertEqual(scannedNames("ab"), ["wxyzabq.txt", "a b.txt"])
    }

    /// A long prefix still outranks a shorter infix — the tier key
    /// decides before the length penalty can outweigh the prefix bonus.
    func testLongPrefixStillBeatsInfix() throws {
        try makeFile("abzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.txt")
        try makeFile("xab.txt")
        XCTAssertEqual(scannedNames("ab"),
                       ["abzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.txt",
                        "xab.txt"])
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

    /// A `.app` package row is an app-icon row — the shared-store ladder
    /// (Pict override, then un-jailed bundle artwork) applies to it the
    /// same as to an `AppSource` result, keyed by the bundle's real ID.
    func testAppPackageItemUsesAppIcon() throws {
        let appURL = root.appendingPathComponent("Fixture.app")
        let plist: [String: Any] = ["CFBundleIdentifier": "com.test.fixture",
                                    "CFBundlePackageType": "APPL"]
        // The setUp fixture already made Fixture.app/Contents, but the
        // plist write shouldn't silently depend on fixture layout.
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true)
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let item = FileSearch.item(for: appURL)
        XCTAssertEqual(item.icon,
                       .appIcon(path: appURL.path, bundleID: "com.test.fixture"))
        XCTAssertEqual(item.action, .openFile(appURL))
    }

    /// A bundle with no readable identifier still gets the path-rung
    /// ladder — a Pict override keyed `app:<path>` still applies.
    func testAppPackageWithoutBundleIDStillUsesAppIcon() throws {
        let bare = root.appendingPathComponent("Bare.app")
        try makeFile("Bare.app/Contents/dummy")
        let item = FileSearch.item(for: bare)
        XCTAssertEqual(item.icon, .appIcon(path: bare.path, bundleID: nil))
    }

    /// Paths under home abbreviate to `~` — the subtitle's compact form.
    func testItemSubtitleAbbreviatesHome() {
        let url = URL(fileURLWithPath:
            NSHomeDirectory() + "/Documents/sheet.numbers")
        XCTAssertEqual(FileSearch.item(for: url).subtitle, "~/Documents")
    }
}
