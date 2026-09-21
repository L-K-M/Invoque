import Darwin
import Dispatch
import Foundation

/// Watches directory trees for created, removed, or renamed entries and
/// fires one debounced callback per burst of events. `AppSource` uses it
/// to notice app installs and uninstalls between launches; `CommandStore`
/// keeps its own copy of this machinery because its fd budget is shared
/// across all command roots rather than spent per tree.
///
/// Each watched directory costs one `O_EVTONLY` descriptor, so the walk is
/// bounded by depth and a target cap. Packages are not descended into —
/// `Foo.app/Contents` changing is an update detail, not an install event —
/// and symlinked directories are listed but not descended into, so a cycle
/// cannot loop the walk. A root that does not exist yet is represented by
/// its nearest existing ancestor, so a later-created `~/Applications`
/// still surfaces.
///
/// All mutable state lives on `queue` (serial); the callback fires there.
/// That serialization is what the `Sendable` conformance asserts.
final class DirectoryWatcher: @unchecked Sendable {

    /// Bounds mirroring `CommandStore`: an fd per directory means depth
    /// and count both need caps so a pathological tree cannot exhaust the
    /// process's descriptor limit.
    private static let maxDepth = 4
    private static let maxTargets = 256

    /// Invoked on the watcher's serial queue once per debounced burst.
    private let onEvent: () -> Void

    /// Serializes source callbacks, the debounce, and target rebuilds.
    private let queue = DispatchQueue(label: "com.invoque.directorywatcher")

    private let roots: [URL]
    private let debounce: TimeInterval
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: Set<String> = []
    private var pending: DispatchWorkItem?
    private var running = false

    init(roots: [URL], debounce: TimeInterval = 0.5,
         onEvent: @escaping () -> Void) {
        self.roots = roots
        self.debounce = debounce
        self.onEvent = onEvent
    }

    /// Starts watching. The initial target resolution runs on the
    /// watcher's queue so callers on main never pay the directory walk.
    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.rebuildTargets()
        }
    }

    /// Stops watching and releases the descriptors. Blocks until the
    /// teardown lands — do not call from the event callback, which runs
    /// on the same serial queue. Never called in the app today — the one
    /// watcher lives as long as `AppSource` — but kept explicit so tests
    /// and future lifecycles have a teardown.
    func stop() {
        queue.sync {
            self.running = false
            self.pending?.cancel()
            self.pending = nil
            self.teardown()
        }
    }

    deinit {
        // Cancel handlers close the descriptors; no queue hop needed.
        sources.forEach { $0.cancel() }
        pending?.cancel()
    }

    /// How many directories are watched right now — exposed for tests,
    /// which poll it to know `start` has finished resolving targets.
    var watchedCount: Int {
        queue.sync { watchedPaths.count }
    }

    // MARK: Events

    /// Schedules the debounced callback. Must run on `queue`.
    private func schedule() {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            // The burst may itself have created directories — re-resolve
            // before firing so the new level is watched from here on.
            self.rebuildTargets()
            self.onEvent()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Watches one directory vnode for writes, renames and deletes. The
    /// descriptor is closed by the source's cancel handler.
    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.schedule()
        }
        source.setCancelHandler { _ = close(descriptor) }
        source.resume()
        return source
    }

    // MARK: Targets

    /// Must run on `queue`.
    private func teardown() {
        sources.forEach { $0.cancel() }
        sources = []
        watchedPaths = []
    }

    /// Recomputes the watched-directory set and rebuilds sources only when
    /// it changed — a content edit inside a watched directory reopens
    /// nothing. Must run on `queue`.
    private func rebuildTargets() {
        var budget = Self.maxTargets
        var seen = Set<String>()
        var targets: [URL] = []
        for root in roots {
            let base = Self.isDirectory(root) ? root
                : Self.nearestExistingAncestor(of: root)
            guard let base, seen.insert(base.path).inserted else { continue }
            targets.append(base)
            budget -= 1
            guard base == root else { continue }
            for sub in Self.subdirectories(under: root, depth: 0, budget: &budget)
                where seen.insert(sub.path).inserted {
                targets.append(sub)
            }
        }
        let paths = Set(targets.map(\.path))
        guard paths != watchedPaths else { return }
        teardown()
        watchedPaths = paths
        sources = targets.compactMap { makeSource(for: $0) }
    }

    /// Subdirectories under `url`, recursively, bounded by depth and the
    /// shared fd budget. Packages (`Foo.app`) and symlinked directories
    /// are not descended into.
    private static func subdirectories(under url: URL, depth: Int,
                                       budget: inout Int) -> [URL] {
        guard depth < maxDepth, budget > 0,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for item in contents {
            guard budget > 0 else { break }
            let values = try? item.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  values?.isPackage != true else { continue }
            found.append(item)
            budget -= 1
            found.append(contentsOf: subdirectories(under: item, depth: depth + 1,
                                                    budget: &budget))
        }
        return found
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// The first ancestor of `url` that exists on disk — watching it means
    /// a later-created root still fires an event (`CommandStore`'s
    /// convention).
    private static func nearestExistingAncestor(of url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.path) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
