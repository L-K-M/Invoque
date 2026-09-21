import Foundation

/// Serves installed apps from an in-memory cache. `items(matching:)` never
/// touches the disk; `reload()` runs on a background queue at launch and
/// whenever the directory watcher reports an install or uninstall under the
/// app folders. The actual scan lives in `AppCatalog`, shared with the
/// `invoque.apps` command module.
/// `Sendable` is asserted: the item cache and reload hook are lock-guarded,
/// and the initial scan deliberately runs on a background queue.
final class AppSource: ItemSource, @unchecked Sendable {

    // MARK: State

    /// Guards `cachedItems`: the initial scan and later watcher-driven
    /// reloads write from a background queue while keystroke reads happen on
    /// the main thread.
    private let lock = NSLock()

    /// Last scan, sorted by title for deterministic iteration. The search hot
    /// path reads this and nothing else.
    private var cachedItems: [Item] = []

    /// Set once the first scan has been published so an empty first scan
    /// still fires `onReload` exactly once — a no-apps machine must not
    /// leave a "scan landed" consumer waiting forever. Guarded by `lock`.
    private var didPublishInitialLoad = false

    /// Notices apps appearing or disappearing under the catalog's search
    /// folders so the cache is not frozen at launch. `lazy` because the
    /// event closure captures `self`, which is only valid once the
    /// non-lazy members above are initialized.
    private lazy var watcher = DirectoryWatcher(
        roots: AppCatalog.searchDirectories) { [weak self] in
        self?.reload()
    }

    /// Backing store for `onReload` — assigned once in `init`, read by
    /// `reload` on a background queue, so reads stay lock-guarded.
    private var _onReload: (() -> Void)?

    /// Fires on the main queue after every reload — the UI re-runs the open
    /// query so results appear as soon as the initial scan lands instead of
    /// waiting for the next keystroke. Read-only: assigning after init
    /// re-opens the missed-first-scan race the init parameter exists to
    /// close.
    var onReload: (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _onReload
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
        watcher.start()
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
    /// nudge; never called per keystroke. `AppCatalog.installedApps()` owns
    /// the invariants this cache relied on: first-directory-wins dedup by
    /// bundle id (`~/Applications` shadows `/Applications`), path-sorted URLs
    /// before dedup so the survivor never flips between reloads, and output
    /// sorted by localized name.
    func reload() {
        let sorted = AppCatalog.installedApps().map(Self.item)
        lock.lock()
        // Directory events fire for any child write — a .DS_Store update
        // included — so an identical scan must not republish and kick a
        // pointless result refresh.
        let changed = sorted != cachedItems || !didPublishInitialLoad
        didPublishInitialLoad = true
        cachedItems = sorted
        // The hook is invoked on main by design — the function value is what
        // crosses the queue boundary, so the sendability exemption sits here
        // rather than on the property's type (a `@Sendable` requirement would
        // leak into every assigner's captures).
        nonisolated(unsafe) let hook = _onReload
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { hook?() }
    }

    // MARK: Mapping

    /// Maps a catalog entry onto a searchable item. The secondary `fileName`
    /// match surface keeps `Firefox.app` findable by its filename even when
    /// the display name localizes to something else. The empty-bundleID
    /// flatMap is belt-and-suspenders: `AppCatalog` already normalizes `""`
    /// to nil, and two malformed apps producing `app.` + `""` would collide
    /// on this id.
    private static func item(for entry: AppEntry) -> Item {
        let bundleID = entry.bundleID.flatMap { $0.isEmpty ? nil : $0 }
        return Item(
            id: Item.appIDPrefix + (bundleID ?? entry.path),
            title: entry.name,
            subtitle: "Application",
            icon: .appIcon(path: entry.path, bundleID: bundleID),
            action: .openApp(URL(fileURLWithPath: entry.path)),
            matchText: "\(entry.name) \(entry.fileName)"
        )
    }
}
