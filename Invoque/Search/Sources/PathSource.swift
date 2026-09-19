import Foundation

/// When the query *is* an existing filesystem path — pasted or typed — the
/// top row is that path itself, not a search candidate. The default action
/// follows the kind: a folder **opens** (in Finder), a file **reveals** —
/// running an arbitrary pasted file is the one thing Return must never do.
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
        let subtitle = isDirectory.boolValue
            ? "Open — \(base.subtitle)"
            : "Reveal in Finder — \(base.subtitle)"
        return [Item(
            id: Item.pathIDPrefix + url.standardizedFileURL.path,
            title: base.title,
            subtitle: subtitle,
            icon: base.icon,
            action: isDirectory.boolValue ? .openFile(url) : .revealInFinder(url),
            matchText: base.matchText
        )]
    }

    // MARK: Resolution

    /// The query as a file URL, or nil when it isn't a path at all:
    /// `/absolute`, `~/…` (and `~user/…`), or a `file://` URL. Bare `~`
    /// resolves to home — still a real path. A `file://` URL's host must be
    /// empty/`localhost`; anything else isn't a local path.
    static func resolve(_ query: String) -> URL? {
        if query.hasPrefix("file://") {
            guard let url = URL(string: query), url.isFileURL else { return nil }
            // `file://host/…` is a remote share, not a local path.
            guard url.host?.isEmpty ?? true || url.host == "localhost" else {
                return nil
            }
            return url
        }
        guard query.hasPrefix("/") || query.hasPrefix("~") else { return nil }
        let path = (query as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
