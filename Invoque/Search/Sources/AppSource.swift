import Foundation

/// Scans the app folders for `.app` bundles and serves them from memory.
/// `items(matching:)` never touches the disk; `reload()` runs on a background
/// queue at launch (and, later, from a file watcher) to refresh.
final class AppSource: ItemSource {

    // MARK: State

    /// Guards `cachedItems`: the initial scan and later watcher-driven
    /// reloads write from a background queue while keystroke reads happen on
    /// the main thread.
    private let lock = NSLock()

    /// Last scan, sorted by title for deterministic iteration. The search hot
    /// path reads this and nothing else.
    private var cachedItems: [Item] = []

    /// Backing store for `onReload` — guarded by `lock` like `cachedItems`,
    /// because reloads read it on a background queue while the owner assigns
    /// it on the main thread.
    private var _onReload: (() -> Void)?

    /// Fires on the main queue after every reload — the UI re-runs the open
    /// query so results appear as soon as the initial scan lands instead of
    /// waiting for the next keystroke.
    var onReload: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onReload
        }
        set {
            lock.lock()
            _onReload = newValue
            lock.unlock()
        }
    }

    // MARK: Init

    /// Kicks off the first scan asynchronously — hundreds of `Bundle` reads
    /// must not stall the launcher's own launch. The source serves an empty
    /// list until the scan lands, then `onReload` fires. Pass the handler
    /// at init rather than assigning it after: a fast first scan could
    /// complete before a post-init assignment and the "scan landed" signal
    /// would be missed entirely.
    init(onReload: (() -> Void)? = nil) {
        _onReload = onReload
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.reload()
        }
    }

    // MARK: ItemSource

    /// The whole cache. Filtering and ranking are `SearchModel`'s job, so
    /// every app stays eligible for frecency-boosted matches.
    func items(matching query: String) -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        return cachedItems
    }

    /// Rescans the app folders. Cheap enough for launch and for a watcher
    /// nudge; never called per keystroke.
    func reload() {
        var found: [Item] = []
        var seenIDs = Set<String>()
        for directory in Self.searchDirectories {
            found.append(contentsOf: scan(directory, seenIDs: &seenIDs))
        }
        let sorted = found.sorted {
            if $0.title != $1.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.id < $1.id
        }
        lock.lock()
        cachedItems = sorted
        let hook = _onReload
        lock.unlock()
        DispatchQueue.main.async { hook?() }
    }

    // MARK: Scanning

    /// The only folders consulted: system-wide, system, and per-user apps,
    /// plus the Utilities subfolders — Terminal, Disk Utility, and Activity
    /// Monitor live there, not in the top-level folders — and CoreServices'
    /// app directory (Archive Utility et al). Order matters: `scan` is
    /// first-directory-wins on duplicate bundle ids, so the per-user folder
    /// leads — a user-installed copy shadows the system-wide one.
    private static var searchDirectories: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
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
