import Darwin
import Dispatch
import Foundation

/// Scans the configured commands roots and keeps the command list current
/// by watching the filesystem.
///
/// Thread safety: all mutable state lives on `stateQueue` (serial). The
/// public getters and `scan()`/`startWatching()`/`stopWatching()` dispatch
/// onto it — so they must not be called from a filesystem event handler.
/// `onChange` is always invoked on the main queue. That serialization is
/// what the `Sendable` conformance asserts.
final class CommandStore: @unchecked Sendable {

    /// A directory under a root that failed to load as a command.
    struct ScanError: Sendable {
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
    private let watchTargetLimit: Int
    private var _commands: [Command] = []
    private var _errors: [ScanError] = []
    private var _scanWatchTargets: [URL] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedTargets: [URL] = []
    private var pendingRescan: DispatchWorkItem?
    /// Bumped on `stateQueue` whenever a rescan is scheduled; an in-flight
    /// pass compares its captured value before committing so a superseded
    /// scan cannot land a stale snapshot last.
    private var rescanGeneration = 0
    private var watching = false

    /// `rootPaths` may use `~`; each is expanded to a file URL.
    /// `watchTargetLimit` exists for tests; production uses the default.
    init(rootPaths: [String] = [CommandStore.defaultRootPath],
         watchTargetLimit: Int = CommandStore.maxWatchTargets) {
        roots = rootPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        self.watchTargetLimit = watchTargetLimit
    }

    /// The most recent scan's commands, sorted by title.
    var commands: [Command] { stateQueue.sync { _commands } }

    /// The configured roots, in scan order — the settings Commands tab
    /// lists them. Immutable since init, so no `stateQueue` hop.
    var rootURLs: [URL] { roots }

    /// The first configured root — where the Maker writes new commands, so
    /// a save is immediately picked up by the store's own scan.
    var primaryRootURL: URL {
        roots.first ?? URL(fileURLWithPath:
            (CommandStore.defaultRootPath as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    /// Directories that failed to load in the most recent scan.
    var scanErrors: [ScanError] { stateQueue.sync { _errors } }

    /// The loaded command named `name`, if any — the panel resolves
    /// `.runCommand` rows through here.
    func command(named name: String) -> Command? {
        commands.first { $0.manifest.name == name }
    }

    /// The watch targets the most recent scan collected — the fd budget in
    /// action, exposed for tests.
    var scanWatchTargets: [URL] { stateQueue.sync { _scanWatchTargets } }

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
    /// `stateQueue`. Returns the committed commands and errors as one
    /// atomic pair — a caller that read them separately could pair this
    /// pass's commands with a later pass's errors.
    @discardableResult
    func scan() -> (commands: [Command], errors: [ScanError]) {
        let outcome = collectCommands()
        return stateQueue.sync {
            commit(outcome)
            return (_commands, _errors)
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
        // One store-wide budget: every target holds an fd, and the total —
        // not the per-command count — is what the process limit sees.
        var watchBudget = watchTargetLimit
        let fileManager = FileManager.default

        for root in roots {
            // A not-yet-created commands root is a normal state, not an
            // error — it simply contributes no commands. Watch the nearest
            // existing ancestor instead so creating the root later (the
            // first-run flow) still triggers a rescan.
            guard fileManager.fileExists(atPath: root.path) else {
                if let ancestor = Self.nearestExistingAncestor(of: root,
                                                               fileManager: fileManager) {
                    watchTargets.append(ancestor)
                }
                continue
            }
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

            let commandDirs = entries.filter { Self.isDirectory($0) }
            for (index, entry) in commandDirs.enumerated() {
                watchTargets.append(entry)
                // Files inside (command.json, main.js, a nested lib/) are
                // watched too: a vnode watch on the directory only catches
                // adds and removes, not in-place content edits. Depth and
                // count are capped — every target is one open fd, and a
                // vendored node_modules would otherwise exhaust them. The
                // remaining budget is split evenly across commands left to
                // scan — with at least one nested target each while any
                // budget remains, so integer division can't starve early
                // commands down to zero when budget < command count (the
                // directory itself is already appended unconditionally).
                let remaining = max(commandDirs.count - index, 1)
                let share = watchBudget > 0
                    ? min(max(watchBudget / remaining, 1), watchBudget)
                    : 0
                var slice = share
                watchTargets.append(contentsOf: Self.watchTargets(
                    under: entry, fileManager: fileManager, depth: 0,
                    budget: &slice))
                watchBudget -= share - slice

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
        _scanWatchTargets = outcome.watchTargets
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

    /// The first ancestor of `url` that exists on disk — watching it means a
    /// later-created commands root still fires a rescan.
    private static func nearestExistingAncestor(of url: URL,
                                                fileManager: FileManager) -> URL? {
        var current = url.deletingLastPathComponent()
        while current.path != "/" {
            if fileManager.fileExists(atPath: current.path) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Files and directories under `url`, recursively — a nested entry like
    /// `lib/main.js` or an edit inside `lib/` must hot-reload too. Symlinked
    /// directories are listed but not descended into, so a symlink cycle
    /// cannot loop the walk forever. `budget` is store-wide and shared
    /// across commands: each watched URL holds a file descriptor, so a
    /// bundled dependency tree (node_modules-scale) or simply many
    /// commands must not exhaust the process's fd limit. Targets past the
    /// cap go unwatched — their edits still surface via a rescan triggered
    /// by a shallower watched ancestor.
    private static let maxWatchDepth = 4
    private static let maxWatchTargets = 256

    private static func watchTargets(under url: URL, fileManager: FileManager,
                                     depth: Int, budget: inout Int) -> [URL] {
        guard depth < maxWatchDepth, budget > 0,
              let contents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var targets: [URL] = []
        for item in contents {
            guard budget > 0 else { break }
            targets.append(item)
            budget -= 1
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                targets.append(contentsOf: watchTargets(under: item, fileManager: fileManager,
                                                        depth: depth + 1, budget: &budget))
            }
        }
        return targets
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
            // A pass already in flight can no longer commit after watching
            // stops (and fire onChange for a store that is not watching).
            rescanGeneration += 1
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
        dispatchPrecondition(condition: .onQueue(stateQueue))
        pendingRescan?.cancel()
        rescanGeneration += 1
        let generation = rescanGeneration
        let rescan = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let outcome = self.collectCommands()
            self.stateQueue.async {
                // cancel() is a no-op once the item has started running, so
                // a superseded pass must drop its own commit — otherwise a
                // slow stale scan could overwrite a fresher one.
                guard self.rescanGeneration == generation else { return }
                self.commit(outcome)
            }
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
