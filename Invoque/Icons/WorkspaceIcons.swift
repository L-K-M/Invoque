import AppKit

/// A bounded cache of `NSWorkspace` file icons, keyed by path — the
/// fallback bitmap a result row draws when the shared store has none.
///
/// Rows resolve icons per body evaluation: a streaming file scan repaints
/// up to `SearchModel.maxResults` rows per batch, and `icon(forFile:)`
/// allocates (and can hit the disk) per call. The cache trades that for a
/// dictionary lookup. Entries are immutable for a given path in practice —
/// an app updating its own icon on disk is the one staleness case, and it
/// already existed behind NSWorkspace's internal icns cache; eviction on
/// the count limit (or memory pressure — `NSCache` obeys both) bounds it.
enum WorkspaceIcons {

    /// Upper bound on cached bitmaps — a result page plus the detached
    /// window, with headroom for scrolled-past rows.
    private static let countLimit = 256

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        return cache
    }()

    /// The workspace icon for `path`, cached. `NSImage` is immutable
    /// enough to share across rows — drawing mutates nothing. A path that
    /// doesn't exist gets the generic document icon and stays uncached:
    /// the placeholder must not outlive the file (a deleted-then-recreated
    /// file in a rescan deserves a fresh lookup).
    static func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if FileManager.default.fileExists(atPath: path) {
            cache.setObject(icon, forKey: key)
        }
        return icon
    }
}
