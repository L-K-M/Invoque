import Foundation

/// Scans the three app folders for `.app` bundles and serves them from
/// memory. `items(matching:)` never touches the disk; call `reload()` on
/// launch (and, later, from a file watcher) to refresh.
final class AppSource: ItemSource {

    // MARK: State

    /// Last scan, sorted by title for deterministic iteration. The search hot
    /// path reads this and nothing else.
    private var cachedItems: [Item] = []

    // MARK: Init

    /// Scans immediately so the source is useful without a manual `reload()`.
    init() {
        reload()
    }

    // MARK: ItemSource

    /// The whole cache. Filtering and ranking are `SearchModel`'s job, so
    /// every app stays eligible for frecency-boosted matches.
    func items(matching query: String) -> [Item] {
        cachedItems
    }

    /// Rescans the app folders. Cheap enough for launch and for a watcher
    /// nudge; never called per keystroke.
    func reload() {
        var found: [Item] = []
        var seenIDs = Set<String>()
        for directory in Self.searchDirectories {
            found.append(contentsOf: scan(directory, seenIDs: &seenIDs))
        }
        cachedItems = found.sorted {
            if $0.title != $1.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    // MARK: Scanning

    /// The only folders consulted: system-wide, system, and per-user apps.
    private static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// One folder, depth 1 only: direct children ending in `.app` via
    /// `contentsOfDirectory`, which never descends, so a nested
    /// `Foo.app/Contents/.../Bar.app` cannot pollute results. Hidden entries
    /// are skipped; an unreadable folder yields nothing rather than breaking
    /// the whole scan. First directory wins on duplicate ids.
    private func scan(_ directory: URL, seenIDs: inout Set<String>) -> [Item] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        var items: [Item] = []
        for url in children where url.pathExtension.lowercased() == "app" {
            let item = Self.item(for: url)
            guard seenIDs.insert(item.id).inserted else { continue }
            items.append(item)
        }
        return items
    }

    /// Builds the item for one bundle URL. The title prefers the localized
    /// display name (`CFBundleDisplayName`, then `CFBundleName`) so it reads
    /// the way Finder shows it, falling back to the filename when the bundle
    /// metadata is unreadable.
    private static func item(for bundleURL: URL) -> Item {
        let bundle = Bundle(url: bundleURL)
        let displayName: String? = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let fileName = bundleURL.deletingPathExtension().lastPathComponent
        let title: String
        if let displayName, !displayName.isEmpty {
            title = displayName
        } else {
            title = fileName
        }
        let identifier = bundle?.bundleIdentifier ?? bundleURL.path
        return Item(
            id: Item.appIDPrefix + identifier,
            title: title,
            subtitle: "Application",
            icon: .appIcon(bundleURL.path),
            action: .openApp(bundleURL),
            matchText: "\(title) \(fileName)"
        )
    }
}
