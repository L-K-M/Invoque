import Foundation

/// When the query *is* a filesystem path — pasted or typed — the top row is
/// the deepest existing component of it, not a search candidate. The default
/// action follows the kind: a folder **opens** (in Finder), a file **reveals**,
/// and anything that could execute — `.app` bundles, +x scripts and
/// binaries — reveals too. Running a pasted path is the one thing Return
/// must never do.
/// `path:` ids pin the row first in `SearchModel`; frecency ignores it
/// (`recordSelection` is opt-in and paths aren't eligible).
final class PathSource: ItemSource {

    // MARK: ItemSource

    /// One row for a resolvable path; nothing otherwise. The row is the
    /// deepest component that exists — usually the query itself, else its
    /// nearest ancestor (see `existingTarget`).
    func items(matching query: String) -> [Item] {
        guard let url = Self.resolve(query),
              let target = Self.existingTarget(for: url) else { return [] }
        // Reuse FileSearch's row shape — filename title, `~`-abbreviated
        // parent, the real file-type icon (app packages included) — then
        // swap the identity and the action. The subtitle leads with the
        // verb so ⏎'s behavior is visible before it's committed.
        let base = FileSearch.item(for: target.url)
        // A directory opens — unless opening it runs code (`isSafeToOpen`
        // covers .app bundles and +x files). Document packages like
        // .xcodeproj or .rtfd open in their editors, so they open.
        let opens = target.isDirectory && Self.isSafeToOpen(target.url)
        let subtitle = opens
            ? "Open — \(base.subtitle)"
            : "Reveal in Finder — \(base.subtitle)"
        return [Item(
            id: Item.pathIDPrefix + target.url.standardizedFileURL.path,
            title: base.title,
            subtitle: subtitle,
            icon: base.icon,
            action: opens ? .openFile(target.url) : .revealInFinder(target.url),
            matchText: base.matchText
        )]
    }

    /// The URL to turn into a row: `url` itself when it exists, else the
    /// deepest ancestor that does — a path-shaped query is direct intent
    /// even when its tail doesn't exist yet (the user is usually
    /// navigating toward it, or about to create it). Root-level folders
    /// and home are never emitted as fallbacks: they're the ancestor of
    /// every `/…` or `~/…` slip (`/Users/jo` → `/Users`), so they'd pin a
    /// catch-all row over real matches on each mistyped prefix. Typing
    /// `/` or `~` itself still produces their rows — the suppression only
    /// covers the fallback.
    static func existingTarget(for url: URL) -> (url: URL, isDirectory: Bool)? {
        var candidate = url
        var fellBack = false
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: candidate.path,
                                              isDirectory: &isDirectory) {
            let parent = candidate.deletingLastPathComponent()
            // `deletingLastPathComponent` bottoms out at the URL itself —
            // stop there rather than looping on `/` forever.
            guard parent.path != candidate.path else { return nil }
            candidate = parent
            fellBack = true
        }
        if fellBack && Self.isCatchAll(candidate) { return nil }
        // A carved-off ancestor always carries the directory hint —
        // re-canonicalize so a *file* ancestor (the `file.txt` in
        // `…/file.txt/x`) doesn't keep a phantom trailing slash.
        var path = candidate.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return (URL(fileURLWithPath: path), isDirectory.boolValue)
    }

    /// Root-level folders and `~` — the ancestors every mistyped absolute
    /// or tilde path converges on.
    private static func isCatchAll(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.split(separator: "/").count <= 1
            || path == FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL.path
    }

    /// Whether `NSWorkspace.open` on `url` could execute code — the one
    /// thing a pasted path must never do. Unsafe: application bundles
    /// (the `.app` extension outright, or any package declaring
    /// `CFBundlePackageType` `APPL`), formats whose default handler runs
    /// them (`.jar`/`.jnlp`, `.workflow`, `.terminal`, `.term`, `.command`,
    /// `.tool`, `.pkg`/`.mpkg` installers, location files (`.inetloc`, `.webloc`,
    /// `.url`, `.fileloc`, `.ftploc`, `.afploc`, `.mailloc`, `.newsloc`,
    /// `.networkloc` — embedded URL/target trampolines),
    /// `.saver`/`.prefPane`/`.menu` plugins), and plain executables
    /// (scripts, binaries with the +x bit). Document packages such as
    /// `.xcodeproj` or `.rtfd` open in their editors — no payload runs —
    /// so they stay openable.
    /// `PanelModel` consults the same policy for the ⌘⏎ inverse.
    static func isSafeToOpen(_ url: URL) -> Bool {
        // Handler-executed formats run on open with no +x bit and no APPL
        // type: `.jar`/`.jnlp` via Java, `.workflow` via Automator,
        // `.terminal`/`.term`/`.command`/`.tool` via Terminal, `.pkg`/`.mpkg` via
        // Installer, and `.saver`/`.prefPane`/`.menu` load plugin code via
        // System Settings/SystemUIServer. Location files (`.inetloc`,
        // `.webloc`, `.url`, `.fileloc` and the `ftp`/`afp`/`mail`/`news`/
        // `network` siblings) hand an embedded URL or target to whatever
        // handler claims it.
        if ["app", "jar", "jnlp", "workflow", "terminal", "term", "command",
            "tool", "pkg", "mpkg", "inetloc", "webloc", "url", "fileloc",
            "ftploc", "afploc", "mailloc", "newsloc", "networkloc", "saver",
            "prefpane", "menu"]
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
    /// `/absolute`, `~/…` (and `~user/…` for a real user — an
    /// unexpandable name comes back unchanged and fails the absolute
    /// check), or a `file://` URL. Bare `~` resolves to home — still a
    /// real path. A `file://` URL's host must be empty/`localhost`;
    /// anything else isn't a local path.
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
            guard url.host?.isEmpty ?? true
                || url.host?.lowercased() == "localhost" else {
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
        // An unexpandable `~user` comes back unchanged — non-absolute,
        // which `fileURLWithPath` would read as cwd-relative.
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
