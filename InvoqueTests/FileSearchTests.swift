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
        let last = SearchModel.maxResults
        for index in 0...last {
            try makeFile(String(format: "fill-%04d.txt", index))
        }
        // Equal-length prefix matches sort by path (%04d keeps them one
        // length whatever the cap): index 0 leads, `last` sits just past
        // the cap. The excluded id comes from the items API so the test
        // pins the walk's key to the id the panel actually blocks, not a
        // hand-built mirror of it.
        let firstName = String(format: "fill-%04d.txt", 0)
        let pastCapName = String(format: "fill-%04d.txt", last)
        let excludedID = try XCTUnwrap(
            FileSearch.items(query: "fill", roots: [root])
                .first { $0.id.hasSuffix(firstName) }?.id)
        let matches = FileSearch.scan(query: "fill", roots: [root],
                                      isExcluded: { $0 == excludedID })
        XCTAssertEqual(matches.count, SearchModel.maxResults)
        let names = matches.map { $0.url.lastPathComponent }
        XCTAssertFalse(names.contains(firstName))
        XCTAssertTrue(names.contains(pastCapName),
                      "the match past the cap must backfill the hole")
    }

    /// A pinned match must survive the cap: with one more match than the
    /// limit, boosting the file that would rank last lifts it into the
    /// output — otherwise a deep-ranked pin would silently do nothing.
    func testBoostedMatchSurvivesTheCap() throws {
        let last = SearchModel.maxResults
        for index in 0...last {
            try makeFile(String(format: "fill-%04d.txt", index))
        }
        // The last index sorts last among the equal-length prefix matches
        // (%04d keeps every filename one length, whatever the cap) — the
        // unboosted scan drops it, the boosted scan must not.
        let boostedName = String(format: "fill-%04d.txt", last)
        let weakestName = String(format: "fill-%04d.txt", last - 1)
        let boostedID = try XCTUnwrap(
            FileSearch.items(query: String(format: "fill-%04d", last),
                             roots: [root]).first?.id)
        XCTAssertEqual(FileSearch.scan(query: "fill", roots: [root])
            .last?.url.lastPathComponent, weakestName)
        let matches = FileSearch.scan(query: "fill", roots: [root],
                                      isBoosted: { $0 == boostedID })
        XCTAssertEqual(matches.count, SearchModel.maxResults)
        XCTAssertEqual(matches.first?.url.lastPathComponent, boostedName)
        XCTAssertFalse(matches.contains {
            $0.url.lastPathComponent == weakestName },
            "the weakest unpinned match yields the slot")
    }

    /// Blocking a directory prunes the whole subtree — "never show" a
    /// folder means its contents too, and pruning keeps descendants from
    /// spending the visited budget.
    func testExcludedDirectoryPrunesSubtree() throws {
        // Control: `sub/deeper-doc.md` is findable while `sub` is allowed.
        XCTAssertEqual(scannedNames("deeper-doc"), ["deeper-doc.md"])
        let excluded = try XCTUnwrap(
            FileSearch.items(query: "sub", roots: [root])
                .first { $0.id.hasSuffix("/sub") }?.id)
        XCTAssertTrue(FileSearch.scan(query: "deeper-doc", roots: [root],
                                      isExcluded: { $0 == excluded }).isEmpty,
                      "descendants of a blocked directory must not match")
        // The directory's own row drops too.
        XCTAssertTrue(FileSearch.scan(query: "sub", roots: [root],
                                      isExcluded: { $0 == excluded }).isEmpty)
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

    // MARK: Scopes

    func testResolvedRootsHome() {
        let roots = FileSearch.resolvedRoots(for: [.home])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].url.standardizedFileURL.path,
                       FileManager.default.homeDirectoryForCurrentUser
                           .standardizedFileURL.path)
        XCTAssertTrue(roots[0].skipPaths.isEmpty)
    }

    /// The system walk never descends /Volumes (those subtrees belong to
    /// the volumes scope) or /System/Volumes — the data volume is already
    /// reachable via the firmlinks at `/`, so walking its real mount
    /// point would double-list every user file.
    func testResolvedRootsSystemSkipsVolumes() {
        let roots = FileSearch.resolvedRoots(for: [.system])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].url.path, "/")
        XCTAssertEqual(roots[0].skipPaths,
                       ["/Volumes", "/System/Volumes"])
    }

    /// With home enabled too, the system walk skips ~ as well — otherwise
    /// the whole home tree is walked (and listed) twice.
    func testResolvedRootsHomeAndSystem() throws {
        let roots = FileSearch.resolvedRoots(for: [.home, .system])
        XCTAssertEqual(roots.count, 2)
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        let system = try XCTUnwrap(roots.first { $0.url.path == "/" })
        XCTAssertTrue(system.skipPaths.contains("/Volumes"))
        XCTAssertTrue(system.skipPaths.contains(home))
    }

    /// Volumes resolve to mounted non-boot volumes — the boot disk must
    /// never appear among them, under `/`, its `/Volumes` alias, or the
    /// `/System/Volumes/*` group. XCTSkip makes the no-external-drives
    /// case explicit rather than a vacuous pass.
    func testResolvedRootsVolumesExcludeBoot() throws {
        let roots = FileSearch.resolvedRoots(for: [.volumes])
        let mounted = Set(
            (FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: []) ?? [])
                .map(\.path))
            .subtracting(["/"])
        guard !mounted.isEmpty else {
            throw XCTSkip("No non-boot volumes mounted — nothing to verify")
        }
        for root in roots {
            let path = root.url.standardizedFileURL.path
            XCTAssertNotEqual(path, "/")
            XCTAssertFalse(path.hasPrefix("/System/Volumes/"))
            XCTAssertTrue(mounted.contains(root.url.path),
                          "\(root.url.path) is not a mounted volume")
        }
    }

    /// An empty scope set is unreachable via the UI and unwritable via
    /// the Preferences decode — but a stale caller gets the default
    /// scope rather than a dead search.
    func testResolvedRootsEmptyFallsBackToHome() {
        XCTAssertEqual(
            FileSearch.resolvedRoots(for: []).map(\.url.path),
            FileSearch.resolvedRoots(for: [.home]).map(\.url.path))
    }

    /// A skip path prunes the whole subtree: the directory itself never
    /// matches (its name is a prefix hit here) and its contents are never
    /// visited — the same "pruned directories are excluded entirely"
    /// contract as a blocked dir.
    func testSkipPathPrunesSubtree() throws {
        try makeFile("keep/keep-notes.txt")
        try makeFile("notes-vault/vault-notes.txt")
        let skip = root.appendingPathComponent("notes-vault")
            .standardizedFileURL.path
        let matches = FileSearch.scan(
            query: "notes",
            roots: [FileSearch.Root(url: root, skipPaths: [skip])])
        // setUp's root/notes.txt matches too — only the vault's entries
        // and the vault itself must be absent. Compared as a Set: rank
        // ordering is covered elsewhere; the contract here is purely
        // which subtrees the walk visits.
        XCTAssertEqual(Set(matches.map(\.url.lastPathComponent)),
                       ["notes.txt", "keep-notes.txt"])
    }
}
