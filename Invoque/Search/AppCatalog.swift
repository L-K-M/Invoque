import Foundation

/// One installed app as the catalog reports it: what the command-side
/// `invoque.apps` module hands to scripts and what `AppSource` maps onto
/// searchable `Item`s.
struct AppEntry: Equatable {
    /// The localized display name (or filename when bundle metadata is
    /// unreadable) — what `apps.launch` matches against.
    let name: String
    /// The bundle's filesystem path.
    let path: String
    /// `CFBundleIdentifier`, or `nil` for malformed/ad-hoc bundles.
    let bundleID: String?
    /// The filename without `.app` — a secondary match surface.
    let fileName: String
}

/// The installed-applications listing, shared by the search `AppSource` and
/// the `invoque.apps` command module. The scan+dedupe+item logic used to live
/// inside `AppSource`; it moved here so a command sees the same app set the
/// launcher itself searches.
enum AppCatalog {

    /// The only folders consulted: system-wide, system, and per-user apps,
    /// and CoreServices' app directory (Archive Utility et al). The
    /// Utilities subfolders are reached by the recursive walks — an
    /// explicit entry would just re-scan them into `seenIDs`. Order matters:
    /// `scan` is first-directory-wins on duplicate bundle ids, so the
    /// per-user folder leads — a user-installed copy shadows the system-wide
    /// one.
    static var searchDirectories: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        ]
    }

    /// Every installed app, deduplicated and sorted by name. Live-scans the
    /// disk — callers that can't tolerate the scan cost cache it (as
    /// `AppSource` does); `invoque.apps.list()` pays it per call, which is
    /// the honest answer to "what's installed *now*".
    static func installedApps() -> [AppEntry] {
        var found: [AppEntry] = []
        var seenIDs = Set<String>()
        for directory in searchDirectories {
            found.append(contentsOf: scan(directory, seenIDs: &seenIDs))
        }
        return found.sorted {
            if $0.name != $1.name {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.path < $1.path
        }
    }

    /// Resolves `query` to a bundle URL: a path (or `file://` URL) naming a
    /// `.app` bundle first, then an exact bundle-id match, then an exact
    /// display-name match — all case-insensitive. Anything fuzzier (prefixes,
    /// substrings) is deliberately left out: a launch is a side effect, so a
    /// command should name the app it means, not the app that sorts first
    /// under a loose match.
    static func resolve(_ query: String, in apps: [AppEntry]) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // A path-ish target is taken literally — bundle existence decides.
        if trimmed.contains("/") || trimmed.hasPrefix("file://") {
            let url = trimmed.hasPrefix("file://")
                ? URL(string: trimmed) : URL(fileURLWithPath: trimmed)
            guard let url, url.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }

        let lowered = trimmed.lowercased()
        if let bundleMatch = apps.first(where: {
            $0.bundleID?.lowercased() == lowered
        }) {
            return URL(fileURLWithPath: bundleMatch.path)
        }
        if let nameMatch = apps.first(where: {
            $0.name.lowercased() == lowered || $0.fileName.lowercased() == lowered
        }) {
            return URL(fileURLWithPath: nameMatch.path)
        }
        return nil
    }

    // MARK: Scanning

    /// One folder, deep: real installs nest apps (`/Applications/Setapp/…`,
    /// `Adobe Photoshop 2025/Adobe Photoshop 2025.app`, user-organized
    /// folders). `.skipsPackageDescendants` keeps the walk out of bundle
    /// interiors — `Foo.app/Contents/.../Bar.app` cannot pollute results.
    /// Hidden entries are skipped; an unreadable folder yields nothing
    /// rather than breaking the whole scan. First directory wins on
    /// duplicate ids.
    private static func scan(_ directory: URL, seenIDs: inout Set<String>) -> [AppEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        // Sort before dedup: enumerator order is filesystem order and not
        // stable across scans, so the survivor among same-bundle-id apps
        // (real app vs. stale backup copy) must not flip between reloads.
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }
        var entries: [AppEntry] = []
        for url in urls {
            let entry = Self.entry(for: url)
            guard seenIDs.insert(Self.identifier(for: entry)).inserted else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Builds the entry for one bundle URL. The name prefers the localized
    /// display name (`CFBundleDisplayName`, then `CFBundleName`) so it reads
    /// the way Finder shows it, falling back to the filename when the bundle
    /// metadata is unreadable.
    private static func entry(for bundleURL: URL) -> AppEntry {
        let bundle = Bundle(url: bundleURL)
        let displayName: String? = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let fileName = bundleURL.deletingPathExtension().lastPathComponent
        let name: String
        if let displayName, !displayName.isEmpty {
            name = displayName
        } else {
            name = fileName
        }
        let bundleID = (bundle?.bundleIdentifier).flatMap { $0.isEmpty ? nil : $0 }
        return AppEntry(name: name, path: bundleURL.path,
                        bundleID: bundleID, fileName: fileName)
    }

    /// The dedupe identity: the bundle id, or the path when it's missing —
    /// an empty `CFBundleIdentifier` (malformed/ad-hoc bundles) would
    /// collide across apps, so it falls back to the path like a missing key.
    private static func identifier(for entry: AppEntry) -> String {
        entry.bundleID ?? entry.path
    }
}
