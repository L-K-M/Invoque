import Darwin
import Dispatch
import Foundation

/// Scans the configured commands roots and keeps the command list current
/// by watching the filesystem.
///
/// Thread safety: all mutable state lives on `stateQueue` (serial). The
/// public getters and `scan()`/`startWatching()`/`stopWatching()` dispatch
/// onto it — so they must not be called from a filesystem event handler.
/// `onChange` is always invoked on the main queue.
final class CommandStore {

    /// A directory under a root that failed to load as a command.
    struct ScanError {
        let directory: URL
        let error: Error
    }

    /// Default commands root — a dotfile-friendly path the user can symlink
    /// into a git repo to sync commands between machines (PLAN §4).
    static let defaultRootPath = "~/.config/invoque/commands"

    /// Debounce window for filesystem events: a burst of saves (or one
    /// atomic-save rename pair) collapses into a single rescan.
    static let rescanDebounce: TimeInterval = 0.3

    /// Invoked on the main queue when a scan produces a different command
    /// list. Not fired for error-only changes.
    var onChange: (([Command]) -> Void)?

    /// Serial queue guarding all state below.
    private let stateQueue = DispatchQueue(label: "com.invoque.commandstore")

    private let roots: [URL]
    private var _commands: [Command] = []
    private var _errors: [ScanError] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedTargets: [URL] = []
    private var pendingRescan: DispatchWorkItem?
    private var watching = false

    /// `rootPaths` may use `~`; each is expanded to a file URL.
    init(rootPaths: [String] = [CommandStore.defaultRootPath]) {
        roots = rootPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    /// The most recent scan's commands, sorted by title.
    var commands: [Command] { stateQueue.sync { _commands } }

    /// Directories that failed to load in the most recent scan.
    var scanErrors: [ScanError] { stateQueue.sync { _errors } }

    deinit {
        // Cancel handlers close the watched descriptors.
        sources.forEach { $0.cancel() }
        pendingRescan?.cancel()
    }

    // MARK: Scanning

    /// A completed filesystem pass, ready to be committed on `stateQueue`.
    private struct ScanOutcome {
        let commands: [Command]
        let errors: [ScanError]
        let watchTargets: [URL]
    }

    /// Rescans and notifies `onChange` if the list changed. The disk pass
    /// runs on the caller's thread; only the state commit hops onto
    /// `stateQueue`. Returns the resulting command list.
    @discardableResult
    func scan() -> [Command] {
        let outcome = collectCommands()
        return stateQueue.sync {
            commit(outcome)
            return _commands
        }
    }

    /// All disk I/O in one pass. Touches no store state, so it can run off
    /// `stateQueue` — keeping the `commands` getter cheap while a rescan is
    /// in flight. Never throws wholesale: a bad command directory is
    /// collected into `errors` and skipped.
    private func collectCommands() -> ScanOutcome {
        var commands: [Command] = []
        var errors: [ScanError] = []
        var watchTargets: [URL] = []
        let fileManager = FileManager.default

        for root in roots {
            // A not-yet-created commands root is a normal state, not an
            // error — it simply contributes no commands.
            guard fileManager.fileExists(atPath: root.path) else { continue }
            watchTargets.append(root)

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
            } catch {
                errors.append(ScanError(directory: root, error: error))
                continue
            }

            for entry in entries where Self.isDirectory(entry) {
                watchTargets.append(entry)
                // Files directly inside (command.json, main.js) are watched
                // too: a vnode watch on the directory only catches adds and
                // removes, not in-place content edits.
                let contents = (try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                watchTargets.append(contentsOf: contents.filter { !Self.isDirectory($0) })

                do {
                    commands.append(try Command(directory: entry))
                } catch {
                    errors.append(ScanError(directory: entry, error: error))
                }
            }
        }

        commands.sort {
            $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending
        }
        return ScanOutcome(commands: commands, errors: errors, watchTargets: watchTargets)
    }

    /// Must run on `stateQueue`. Commits a collected pass: swaps the command
    /// list, rebuilds watchers only when the target set actually changed
    /// (a content edit inside a watched directory reopens nothing), and
    /// fires `onChange` on the main queue.
    private func commit(_ outcome: ScanOutcome) {
        let changed = outcome.commands != _commands
        _commands = outcome.commands
        _errors = outcome.errors
        if watching, outcome.watchTargets != watchedTargets {
            rebuildWatchers(outcome.watchTargets)
        }
        if changed {
            let snapshot = outcome.commands
            DispatchQueue.main.async { self.onChange?(snapshot) }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: Watching

    /// Starts watching roots and command directories, and performs an
    /// initial scan. The disk pass runs on the caller's thread.
    func startWatching() {
        stateQueue.sync { watching = true }
        let outcome = collectCommands()
        stateQueue.sync { commit(outcome) }
    }

    func stopWatching() {
        stateQueue.sync {
            watching = false
            pendingRescan?.cancel()
            pendingRescan = nil
            tearDownWatchers()
        }
    }

    /// Schedules a debounced rescan after a filesystem event. Runs on
    /// `stateQueue` (the sources' target queue); the disk pass itself hops
    /// to a utility queue so a burst of events never stalls the getters.
    /// Weak self: the item is retained by `pendingRescan` — a strong capture
    /// would pin the store for the debounce window, and a rescan that
    /// outlives its store has nothing to commit to anyway.
    private func scheduleRescan() {
        pendingRescan?.cancel()
        let rescan = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let outcome = self.collectCommands()
            self.stateQueue.async { self.commit(outcome) }
        }
        pendingRescan = rescan
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.rescanDebounce, execute: rescan)
    }

    /// Must run on `stateQueue`.
    private func rebuildWatchers(_ urls: [URL]) {
        tearDownWatchers()
        sources = urls.compactMap { makeSource(for: $0) }
        watchedTargets = urls
    }

    /// Must run on `stateQueue`.
    private func tearDownWatchers() {
        sources.forEach { $0.cancel() }
        sources = []
        watchedTargets = []
    }

    /// Watches one file or directory vnode for writes, renames and deletes.
    /// The descriptor is closed by the source's cancel handler.
    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: stateQueue)
        source.setEventHandler { [weak self] in
            self?.scheduleRescan()
        }
        source.setCancelHandler { _ = close(descriptor) }
        source.resume()
        return source
    }
}
