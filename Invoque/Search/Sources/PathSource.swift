import Foundation

/// When the query *is* an existing filesystem path — pasted or typed — the
/// top row is that path itself, not a search candidate. The default action
/// follows the kind: a folder **opens** (in Finder), a file **reveals**,
/// and anything that could execute — `.app` bundles, +x scripts and
/// binaries — reveals too. Running a pasted path is the one thing Return
/// must never do.
/// `path:` ids pin the row first in `SearchModel`; frecency ignores it
/// (`recordSelection` is opt-in and paths aren't eligible).
final class PathSource: ItemSource {

    // MARK: ItemSource

    /// One row for a resolvable, existing path; nothing otherwise — a
    /// mid-typing prefix like `/us` simply isn't a path yet.
    func items(matching query: String) -> [Item] {
        guard let url = Self.resolve(query) else { return [] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory) else {
            return []
        }
        // Reuse FileSearch's row shape — filename title, `~`-abbreviated
        // parent, the real file-type icon (app packages included) — then
        // swap the identity and the action. The subtitle leads with the
        // verb so ⏎'s behavior is visible before it's committed.
        let base = FileSearch.item(for: url)
        // A directory opens — unless opening it runs code (`isSafeToOpen`
        // covers .app bundles and +x files). Document packages like
        // .xcodeproj or .rtfd open in their editors, so they open.
        let opens = isDirectory.boolValue && Self.isSafeToOpen(url)
        let subtitle = opens
            ? "Open — \(base.subtitle)"
            : "Reveal in Finder — \(base.subtitle)"
        return [Item(
            id: Item.pathIDPrefix + url.standardizedFileURL.path,
            title: base.title,
            subtitle: subtitle,
            icon: base.icon,
            action: opens ? .openFile(url) : .revealInFinder(url),
            matchText: base.matchText
        )]
    }

    /// Whether `NSWorkspace.open` on `url` could execute code — the one
    /// thing a pasted path must never do. Unsafe: application bundles
    /// (the `.app` extension outright, or any package declaring
    /// `CFBundlePackageType` `APPL`), formats whose default handler runs
    /// them (`.jar`, `.workflow`, `.terminal`), and plain executables
    /// (scripts, binaries with the +x bit). Document packages such as
    /// `.xcodeproj` or `.rtfd` open in their editors — no payload runs —
    /// so they stay openable.
    /// `PanelModel` consults the same policy for the ⌘⏎ inverse.
    static func isSafeToOpen(_ url: URL) -> Bool {
        // `.jar`, `.workflow`, `.terminal` run via their default handler on
        // open — no +x bit, no APPL type — so they reveal like apps.
        if ["app", "jar", "workflow", "terminal"]
            .contains(url.pathExtension.lowercased()) { return false }
        if (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundlePackageType")
            as? String) == "APPL" {
            return false
        }
        // `fileExists` follows symlinks — `URL.resourceValues` reports the
        // link itself, so `/tmp` (→ `/private/tmp`) would look like a file
        // and then trip `isExecutableFile` (dirs are "executable" = searchable).
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path,
                                       isDirectory: &isDirectory)
        guard !isDirectory.boolValue else { return true }
        return !FileManager.default.isExecutableFile(atPath: url.path)
    }

    // MARK: Resolution

    /// The query as a file URL, or nil when it isn't a path at all:
    /// `/absolute`, `~/…` (and `~user/…`), or a `file://` URL. Bare `~`
    /// resolves to home — still a real path. A `file://` URL's host must be
    /// empty/`localhost`; anything else isn't a local path.
    static func resolve(_ query: String) -> URL? {
        if query.hasPrefix("file://") {
            // A parsed `?`/`#` would silently truncate the path — those
            // inputs take the raw-remainder branch so they stay literal.
            guard let url = URL(string: query), url.isFileURL,
                  url.query == nil, url.fragment == nil else {
                // `URL(string:)` rejects unencoded spaces/non-ASCII. The
                // remainder is then a raw path (`file:///a b` → `/a b`);
                // an encoded paste would have parsed above. After the
                // scheme and an optional `localhost` host, anything not
                // starting with `/` names a remote share.
                var rest = query.dropFirst("file://".count)
                if rest.lowercased().hasPrefix("localhost") {
                    rest = rest.dropFirst("localhost".count)
                }
                guard rest.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: String(rest))
            }
            // `file://host/…` is a remote share, not a local path.
            guard url.host?.isEmpty ?? true || url.host == "localhost" else {
                return nil
            }
            // Re-canonicalize through `fileURLWithPath` so `file:///tmp` and
            // a typed `/tmp` produce the same URL — directory-ness affects
            // the trailing slash, and `URL(string:)` doesn't check it. An
            // empty path (`file://` alone) would otherwise resolve to cwd.
            guard !url.path.isEmpty else { return nil }
            return URL(fileURLWithPath: url.path)
        }
        guard query.hasPrefix("/") || query.hasPrefix("~") else { return nil }
        let path = (query as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
