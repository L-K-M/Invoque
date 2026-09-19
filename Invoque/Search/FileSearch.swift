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
/// - Package interiors (`.skipsPackageDescendants`) and `node_modules` are
///   never entered; they are noise for "find a file" intent.
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

    /// Directory names never descended into. Hidden directories are already
    /// pruned by the `isHidden` check; this list is for visible-but-noisy
    /// trees.
    static let skippedDirectoryNames: Set<String> = ["node_modules"]

    /// Hard stop on total entries enumerated across all roots — bounds a
    /// pathological tree (or a root that turned out to be a mount).
    static var maxVisited = 500_000

    /// Matches kept for ranking. Larger than the panel's row cap so the top
    /// of the list is a fair sort, not first-seen order.
    static var maxMatches = 500

    /// `isCancelled` is polled on this stride — cheap enough to stay
    /// responsive, rare enough not to tax the walk.
    private static let cancellationStride = 2_048

    /// A fuzzy hit: the file's URL and its `FuzzyMatcher` score.
    struct Match {
        let url: URL
        let score: Int
    }

    /// Ranked matches for `query` under `roots`, best first, at most
    /// `SearchModel.maxResults`. Matching is on the last path component —
    /// directories match like files (picking one opens it). Returns `[]` for
    /// a blank query: "match everything" floods would defeat the point.
    static func scan(query: String, roots: [URL] = defaultRoots,
                     isCancelled: () -> Bool = { false }) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCancelled() else { return [] }

        var visited = 0
        var matches: [Match] = []
        var seenPaths = Set<String>()
        for root in roots {
            walk(root, query: trimmed, isCancelled: isCancelled,
                 visited: &visited, matches: &matches, seenPaths: &seenPaths)
            if visited >= maxVisited || isCancelled() { break }
        }
        // Score desc, then path for a stable tie-break — identical queries
        // must produce identical lists.
        return matches
            .sorted { $0.score != $1.score ? $0.score > $1.score
                                           : $0.url.path < $1.url.path }
            .prefix(SearchModel.maxResults)
            .map { $0 }
    }

    /// Ranked matches mapped to items — filename, `~`-abbreviated parent
    /// path, the file-type icon, and an `openFile` action.
    static func items(query: String, roots: [URL] = defaultRoots,
                      isCancelled: () -> Bool = { false }) -> [Item] {
        scan(query: query, roots: roots, isCancelled: isCancelled).map {
            item(for: $0.url)
        }
    }

    /// One root, deep. `isHidden` is prefetched so the per-entry check stays
    /// cheap; a hidden directory is pruned via `skipDescendants` rather than
    /// `.skipsHiddenFiles`, which would drop hidden files too.
    private static func walk(_ root: URL, query: String,
                             isCancelled: () -> Bool,
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
            if values?.isDirectory == true,
               (values?.isHidden == true
                || skippedDirectoryNames.contains(url.lastPathComponent)) {
                enumerator.skipDescendants()
                continue
            }
            guard seenPaths.insert(url.standardizedFileURL.path).inserted else { continue }
            if let score = FuzzyMatcher.score(query, candidate: url.lastPathComponent) {
                matches.append(Match(url: url, score: score))
                if matches.count >= maxMatches { return }
            }
        }
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
        return Item(
            id: Item.fileIDPrefix + url.standardizedFileURL.path,
            title: name,
            subtitle: String(subtitle),
            icon: .fileURL(url),
            action: .openFile(url),
            matchText: name
        )
    }
}
