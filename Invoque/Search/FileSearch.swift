import Foundation

/// Spotlight-free filename search: a plain recursive directory walk, run on
/// demand for `find <query>` / `f <query>` panel sessions.
///
/// No index and no metadata store — `NSMetadataQuery` (Spotlight) misses
/// files in unsanctioned or excluded locations, so this walks the disk
/// directly like Alfred's `find` fallback. APFS enumeration is fast enough
/// for interactive use once the noisy trees are pruned:
///
/// - Hidden *directories* are skipped (`~/Library`, `.git`, `~/.cache`) — the
///   single biggest win — while hidden *files* in visible directories still
///   match, so `~/.zshrc` remains findable.
/// - Package interiors (`.skipsPackageDescendants`), dependency trees
///   (`node_modules`, `Pods`, `venv`), and manifest-adjacent build dirs
///   (`target`, `build`, `dist`) are never entered — noise for "find a
///   file" intent. Pruned directories are excluded from matches entirely:
///   the walk `continue`s before scoring, so their own names can't hit.
/// - `maxVisited` bounds the worst case on giant trees; `maxMatches` bounds
///   the sort input. Both are `var` so tests can shrink them.
///
/// The scan is synchronous by design: `PanelModel` runs it inside the
/// debounced mode task, where the `isCancelled` probe sees that task's
/// cancellation. Tests call it directly.
enum FileSearch {

    /// The roots a default scan walks. Home only — the same scope Alfred's
    /// file search assumes.
    static var defaultRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser]
    }

    /// Directory names never descended into — compared case-insensitively
    /// (a case-insensitive volume can't distinguish them anyway). Hidden
    /// directories are pruned separately via `isHidden`.
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", "pods", "venv",
    ]

    /// Generic names pruned only next to a project manifest — a hand-made
    /// `~/Documents/build` folder's files are real and must stay findable,
    /// while `proj/target` beside `Cargo.toml` is generated output.
    static let projectScopedDirectoryNames: Set<String> = [
        "target", "build", "dist",
    ]

    /// Files whose presence beside a `projectScopedDirectoryNames` entry
    /// marks it as generated output worth skipping.
    private static let projectManifestNames = [
        "package.json", "Cargo.toml", "Podfile", "Package.swift",
        "pom.xml", "pyproject.toml", "Makefile", "CMakeLists.txt",
        "setup.py", "go.mod", "meson.build", "build.gradle",
    ]

    /// Hard stop on total entries enumerated across all roots — bounds a
    /// pathological tree (or a root that turned out to be a mount).
    static var maxVisited = 500_000

    /// Matches kept for ranking. Larger than the panel's row cap so the top
    /// of the list is a fair sort, not first-seen order.
    static var maxMatches = 500

    /// `isCancelled` is polled on this stride — cheap enough to stay
    /// responsive, rare enough not to tax the walk.
    private static let cancellationStride = 2_048

    /// A filename hit: the file's URL plus its match tier and score.
    struct Match {
        let url: URL
        let tier: FuzzyMatcher.Match.Tier
        let score: Int
    }

    /// Ranked matches for `query` under `roots`, best first, at most
    /// `SearchModel.maxResults`. Matching is on the last path component —
    /// directories match like files (picking one opens it). Returns `[]` for
    /// a blank query: "match everything" floods would defeat the point.
    ///
    /// `isExcluded` (on the `file:` item id) drops rows during the walk,
    /// before the cap — blocked files leave no hole in the result list
    /// because the next-best match backfills their slot. An excluded
    /// *directory* is pruned whole: its subtree never matches and never
    /// spends the visited budget — "block this folder" means its contents
    /// too, not just the folder's own row.
    /// `isBoosted` (same id) lifts pinned matches ahead of the cap in rank
    /// order — a pin ranked past `maxResults` would otherwise be cut and
    /// the pin would silently do nothing in file mode.
    static func scan(query: String, roots: [URL] = defaultRoots,
                     isCancelled: () -> Bool = { false },
                     isExcluded: (String) -> Bool = { _ in false },
                     isBoosted: (String) -> Bool = { _ in false }) -> [Match] {
        let trimmed = SearchModel.normalizedQuery(query)
        guard !trimmed.isEmpty, !isCancelled() else { return [] }

        var visited = 0
        var matches: [Match] = []
        var seenPaths = Set<String>()
        for root in roots {
            walk(root, query: trimmed, isCancelled: isCancelled,
                 isExcluded: isExcluded,
                 visited: &visited, matches: &matches, seenPaths: &seenPaths)
            if visited >= maxVisited || isCancelled() { break }
        }
        // Same ordering the launcher search uses: match tier first (prefix
        // beats infix beats fuzzy), then the shorter filename, then the
        // alignment score, then path — the total order keeps identical
        // queries producing identical lists.
        let ranked = matches.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let lhsLength = lhs.url.lastPathComponent.count
            let rhsLength = rhs.url.lastPathComponent.count
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.url.path < rhs.url.path
        }
        // Boosted ids lead the capped output — a pinned match has to
        // survive the cap or pinning it would silently do nothing. The
        // unpinned fill the rest in rank order.
        var boosted: [Match] = []
        var rest: [Match] = []
        for match in ranked {
            if isBoosted(Self.fileID(for: match.url)) {
                boosted.append(match)
            } else {
                rest.append(match)
            }
        }
        return Array((boosted + rest).prefix(SearchModel.maxResults))
    }

    /// Ranked matches mapped to items — filename, `~`-abbreviated parent
    /// path, the file-type icon, and an `openFile` action.
    static func items(query: String, roots: [URL] = defaultRoots,
                      isCancelled: () -> Bool = { false },
                      isExcluded: (String) -> Bool = { _ in false },
                      isBoosted: (String) -> Bool = { _ in false }) -> [Item] {
        scan(query: query, roots: roots, isCancelled: isCancelled,
             isExcluded: isExcluded, isBoosted: isBoosted).map {
            item(for: $0.url)
        }
    }

    /// One root, deep. `isHidden` is prefetched so the per-entry check stays
    /// cheap; a hidden directory is pruned via `skipDescendants` rather than
    /// `.skipsHiddenFiles`, which would drop hidden files too.
    private static func walk(_ root: URL, query: String,
                             isCancelled: () -> Bool,
                             isExcluded: (String) -> Bool,
                             visited: inout Int, matches: inout [Match],
                             seenPaths: inout Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isHiddenKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % cancellationStride == 0, isCancelled() { return }
            if visited > maxVisited { return }

            let values = try? url.resourceValues(forKeys: [.isHiddenKey, .isDirectoryKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent.lowercased()
                // A blocked directory prunes its whole subtree — paying the
                // id build only for directories keeps plain files cheap.
                if values?.isHidden == true
                    || skippedDirectoryNames.contains(name)
                    || (projectScopedDirectoryNames.contains(name)
                        && hasProjectManifest(beside: url))
                    || isExcluded(Self.fileID(for: url)) {
                    enumerator.skipDescendants()
                    continue
                }
            }
            // Dedupe inside the match branch: seenPaths only exists to
            // keep a twice-yielded path (overlapping roots) out of the
            // results, so recording non-matches would grow the set to
            // `visited` size for nothing.
            if let match = FuzzyMatcher.match(query, candidate: url.lastPathComponent) {
                let path = url.standardizedFileURL.path
                if !isExcluded(Self.fileID(forPath: path)),
                   seenPaths.insert(path).inserted {
                    matches.append(Match(url: url, tier: match.tier,
                                         score: match.score))
                    if matches.count >= maxMatches { return }
                }
            }
        }
    }

    /// Whether `directory`'s parent holds a project manifest — the signal
    /// that a generically-named dir (`build`, `dist`, `target`) is
    /// generated output rather than user content.
    private static func hasProjectManifest(beside directory: URL) -> Bool {
        let parent = directory.deletingLastPathComponent()
        return projectManifestNames.contains {
            FileManager.default.fileExists(
                atPath: parent.appendingPathComponent($0).path)
        }
    }

    /// The row's stable id — one construction for every `file:` id so the
    /// walk's exclusion keys can never drift from the id a row displays.
    private static func fileID(for url: URL) -> String {
        fileID(forPath: url.standardizedFileURL.path)
    }

    private static func fileID(forPath path: String) -> String {
        Item.fileIDPrefix + path
    }

    /// The result row's data: stable `file:` id on the resolved path, the
    /// filename as title, and the parent directory abbreviated to `~` when
    /// it lives under home — "~/Documents" reads better than the full path.
    static func item(for url: URL) -> Item {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let subtitle = parent == home ? "~"
            : parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count)
            : parent
        // An `.app` package is an app-icon row, not a file-icon row: the
        // shared-store ladder (Pict override, then un-jailed bundle
        // artwork) applies to it the same as to an `AppSource` result. The
        // bundle read runs once per matched app — bounded by the result
        // cap, not by the walk.
        let icon: Item.Icon = url.pathExtension.lowercased() == "app"
            ? .appIcon(path: url.path,
                       bundleID: Bundle(url: url)?.bundleIdentifier
                           .flatMap { $0.isEmpty ? nil : $0 })
            : .fileURL(url)
        return Item(
            id: fileID(for: url),
            title: name,
            subtitle: String(subtitle),
            icon: icon,
            action: .openFile(url),
            matchText: name
        )
    }
}
