import Foundation

/// Serves installed apps from an in-memory cache. `items(matching:)` never
/// touches the disk; `reload()` runs on a background queue at launch (and,
/// later, from a file watcher) to refresh. The actual scan lives in
/// `AppCatalog`, shared with the `invoque.apps` command module.
final class AppSource: ItemSource {

    // MARK: State

    /// Guards `cachedItems`: the initial scan and later watcher-driven
    /// reloads write from a background queue while keystroke reads happen on
    /// the main thread.
    private let lock = NSLock()

    /// Last scan, sorted by title for deterministic iteration. The search hot
    /// path reads this and nothing else.
    private var cachedItems: [Item] = []

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
        let sorted = AppCatalog.installedApps().map(Self.item)
        lock.lock()
        cachedItems = sorted
        let hook = _onReload
        lock.unlock()
        DispatchQueue.main.async { hook?() }
    }

    // MARK: Mapping

    /// Maps a catalog entry onto a searchable item. The secondary `fileName`
    /// match surface keeps `Firefox.app` findable by its filename even when
    /// the display name localizes to something else.
    private static func item(for entry: AppEntry) -> Item {
        Item(
            id: Item.appIDPrefix + (entry.bundleID ?? entry.path),
            title: entry.name,
            subtitle: "Application",
            icon: .appIcon(entry.path),
            action: .openApp(URL(fileURLWithPath: entry.path)),
            matchText: "\(entry.name) \(entry.fileName)"
        )
    }
}
