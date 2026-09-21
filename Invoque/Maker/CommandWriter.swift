import Foundation

/// Persists a validated generation as a command directory under the store's
/// primary root: `command.json` (normalized — pretty-printed, sorted keys,
/// `generated` provenance filled in), the entry file, any extra files, and
/// `data/`.
///
/// Updating an existing command snapshots the previous `command.json` and
/// entry file into `history/<yyyy-MM-dd'T'HHmmss>/` first and bumps
/// `generated.revision` — rollback is then a file copy the user can do by
/// hand (PLAN §6).
///
/// The writer never evaluates generated code: saving is pure file I/O, and
/// first run stays user-triggered (AGENTS.md).
struct CommandWriter {

    enum SaveError: Error, Equatable, LocalizedError {
        /// The manifest JSON couldn't be re-serialized — shouldn't happen
        /// after validation, but a writer must not half-write a command.
        case manifestNotObject
        /// A file name would write outside the command directory. The parser
        /// already rejects these; the writer re-checks because it is the last
        /// thing between a generated string and the filesystem.
        case unsafeFileName(String)
        /// The manifest text being persisted failed to decode or validate —
        /// distinct from `manifestNotObject` (a re-serialization failure):
        /// `generation.manifestJSON` is decoded and checked here so the
        /// bytes on disk are the bytes that were validated.
        case manifestInvalid(String)
        /// The manifest's `entry` isn't among the generated files — checked
        /// pre-flight so nothing is written at all in this state.
        case entryNotPresent(String)
        /// Existing symlinks or unexpected command-owned items make the
        /// destination unsafe to update.
        case unsafeCommandDirectory(String)

        var errorDescription: String? {
            switch self {
            case .manifestNotObject:
                return "command.json isn't a JSON object"
            case .unsafeFileName(let name):
                return "refusing to write '\(name)' — not a safe relative path"
            case .manifestInvalid(let detail):
                return "generated command.json isn't a valid manifest: \(detail)"
            case .entryNotPresent(let entry):
                return "manifest entry '\(entry)' isn't among the generated files"
            case .unsafeCommandDirectory(let detail):
                return "refusing to update an unsafe command directory: \(detail)"
            }
        }
    }

    /// The commands root the writer saves into.
    let rootURL: URL

    /// `rootPath` may use `~`, like `CommandStore`'s root list.
    init(rootPath: String = CommandStore.defaultRootPath) {
        self.init(rootURL: URL(fileURLWithPath:
            (rootPath as NSString).expandingTildeInPath, isDirectory: true))
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: Save

    /// Writes (or updates) the command described by `generation`. Returns
    /// the command directory URL. Call `CommandStore.scan()` afterward — the
    /// filesystem watcher also picks the write up, but an explicit rescan
    /// makes the new command visible immediately.
    @discardableResult
    func save(_ generation: GeneratedCommand,
              prompt: String,
              model: String,
              fileManager: FileManager = .default) throws -> URL {
        // Last-line defense: validate the manifest text that will actually
        // be persisted — decoding `generation.manifestJSON` here means the
        // bytes on disk are the bytes that were checked. The slug rule
        // means `name` cannot traverse.
        let persisted: CommandManifest
        do {
            persisted = try JSONDecoder().decode(
                CommandManifest.self, from: Data(generation.manifestJSON.utf8))
            try persisted.validateStructure()
        } catch {
            // DecodingError's localizedDescription is just "The data
            // couldn't be read…" — describe the error so it's debuggable.
            throw SaveError.manifestInvalid(String(describing: error))
        }
        // The name selects the directory — the writer doesn't trust
        // upstream validation alone for the one value that picks a path.
        guard !persisted.name.isEmpty, !persisted.name.contains("/"),
              persisted.name != ".", persisted.name != ".." else {
            throw SaveError.unsafeFileName(persisted.name)
        }
        let directory = rootURL.appendingPathComponent(persisted.name, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("command.json")

        // Pre-flight every file name before anything is written — an unsafe
        // or reserved name surfacing after the history snapshot or the
        // manifest write would leave a half-written command behind.
        // `data`/`history` are the command's own directories; `command.json`
        // is written from the normalized manifest, so a generated file that
        // only differs in case would silently overwrite it on APFS — the
        // comparison is case-insensitive for the same reason.
        var seenCaseFolded = Set<String>()
        for name in generation.files.keys {
            let firstComponent = name.components(separatedBy: "/")
                .first?.lowercased()
            guard Self.isSafeRelativePath(name),
                  firstComponent != "data", firstComponent != "history",
                  name == "command.json" || name.lowercased() != "command.json",
                  // Two names differing only by case collide on APFS —
                  // the second write would silently replace the first.
                  seenCaseFolded.insert(name.lowercased()).inserted else {
                throw SaveError.unsafeFileName(name)
            }
        }
        // The manifest's entry must be among the generated files — without
        // it the saved command fails to load at scan time. `command.json`
        // itself is never a valid entry: it exists in `files` (as the
        // manifest text), but "running" it would evaluate JSON.
        guard generation.files[persisted.entry] != nil,
              persisted.entry.lowercased() != "command.json" else {
            throw SaveError.entryNotPresent(persisted.entry)
        }

        // Existing command-owned paths must not redirect the snapshot or
        // generated writes through symlinks. This runs before any mutation.
        do {
            _ = try CommandDirectoryPolicy.validatedStorageURL(in: directory)
            var destinations = Array(generation.files.keys)
            destinations.append(contentsOf: [
                "command.json", "data", "data/storage.json", "history",
            ])
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: directory,
                relativePaths: destinations)
        } catch {
            throw SaveError.unsafeCommandDirectory(error.localizedDescription)
        }

        let snapshot = try snapshotExisting(in: directory,
                                            fileManager: fileManager)
        let manifestData = try normalizedManifest(generation.manifestJSON,
                                                  revision: snapshot.revision + 1,
                                                  prompt: prompt, model: model)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in generation.files
            where name.lowercased() != "command.json" {
                guard Self.isSafeRelativePath(name) else {
                    throw SaveError.unsafeFileName(name)
                }
                let fileURL = directory.appendingPathComponent(name)
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            // `data/` always exists so `invoque.fs`/`storage` have their
            // scope — it stays empty until the command itself writes.
            try fileManager.createDirectory(
                at: directory.appendingPathComponent("data", isDirectory: true),
                withIntermediateDirectories: true)
            // The manifest is the commit point — written last.
            try manifestData.write(to: manifestURL, options: .atomic)
        } catch {
            // Roll back so a failed save never leaves old manifest + new
            // files: the runtime would otherwise apply the previous
            // permissions to code they were never checked against.
            rollback(snapshot, removingGenerated: generation.files.keys,
                     in: directory, fileManager: fileManager)
            throw error
        }
        if snapshot.wasGenerated {
            pruneStaleFiles(in: directory, generation: generation,
                            snapshotURL: snapshot.url, fileManager: fileManager)
        }
        return directory
    }

    // MARK: History

    /// What `snapshotExisting` learned about the command being replaced —
    /// enough to bump the revision, roll back a failed save, and know
    /// whether pruning dropped files is safe.
    private struct ExistingSnapshot {
        var revision = 0
        /// The old manifest was maker-generated — its extra files are
        /// fair to prune on update. Hand-authored commands keep theirs.
        var wasGenerated = false
        /// The `history/<timestamp>/` directory, `nil` for a fresh save.
        var url: URL?
        /// Relative paths actually snapshotted (manifest plus old entry).
        var fileNames: [String] = []
    }

    /// If `directory` already holds a command, copies its `command.json` and
    /// entry file into `history/<timestamp>/` and describes them in the
    /// returned snapshot. The snapshot happens before any write, so the
    /// rollback path can restore the old command on a failed save.
    private func snapshotExisting(in directory: URL,
                                  fileManager: FileManager) throws -> ExistingSnapshot {
        var snapshot = ExistingSnapshot()
        let manifestURL = directory.appendingPathComponent("command.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return snapshot
        }

        // The previous entry name comes from the previous manifest — usually
        // "main.js", but a hand-edited command may differ. An undecodable old
        // manifest still snapshots command.json alone.
        let oldManifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(CommandManifest.self, from: $0) }
        snapshot.revision = oldManifest?.generated?.revision ?? 0
        snapshot.wasGenerated = oldManifest?.generated != nil

        if let oldEntry = oldManifest?.entry {
            guard Self.isSafeRelativePath(oldEntry) else {
                throw SaveError.unsafeCommandDirectory(
                    "manifest entry '\(oldEntry)' is not a safe relative path")
            }
            do {
                try CommandDirectoryPolicy.validateWriteDestinations(
                    in: directory,
                    relativePaths: [oldEntry])
            } catch {
                throw SaveError.unsafeCommandDirectory(error.localizedDescription)
            }
        }

        let snapshotURL = uniqueSnapshotDirectory(in: directory, fileManager: fileManager)
        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        snapshot.url = snapshotURL
        var names = ["command.json"]
        if let oldEntry = oldManifest?.entry { names.append(oldEntry) }
        for name in names {
            guard Self.isSafeRelativePath(name) else { continue }
            let source = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = snapshotURL.appendingPathComponent(name)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            snapshot.fileNames.append(name)
        }
        return snapshot
    }

    /// A failed save restores the snapshotted manifest and entry — without
    /// it the directory holds old manifest + new files, a mixed-revision
    /// state where the runtime applies permissions the new code was never
    /// checked against. A fresh command's partial writes are removed —
    /// created directories (`data/`, the command dir itself) may remain,
    /// since a user-created `data/` without a manifest is possible and
    /// must not be deleted. New files the failed generation introduced
    /// stay behind as inert
    /// extras the old manifest doesn't reference (a later generated save
    /// prunes them); byte-for-byte rollback of every file is the deferred
    /// snapshot-all-files work.
    private func rollback(_ snapshot: ExistingSnapshot,
                          removingGenerated names: Dictionary<String, String>.Keys,
                          in directory: URL,
                          fileManager: FileManager) {
        if let snapshotURL = snapshot.url {
            for name in snapshot.fileNames {
                // Atomic in-place restore — a delete-then-copy window would
                // leave no manifest at all when the restore itself fails
                // (a full/read-only volume being the likely cause).
                if let restored = try? Data(
                    contentsOf: snapshotURL.appendingPathComponent(name)) {
                    try? restored.write(
                        to: directory.appendingPathComponent(name),
                        options: .atomic)
                }
            }
        } else {
            for name in names where Self.isSafeRelativePath(name) {
                try? fileManager.removeItem(
                    at: directory.appendingPathComponent(name))
            }
        }
    }

    /// An update should leave the directory matching the generation —
    /// files a new revision dropped (a renamed entry, a removed helper)
    /// are moved into the fresh history snapshot rather than deleted:
    /// recoverable beats gone, and a user-dropped notes.md or .env
    /// survives a regeneration. `data/` and `history/` are runtime state
    /// and always stay, and only maker-generated commands are pruned —
    /// a hand-authored command may carry files the generation never knew
    /// about. Runs after the manifest commit, so everything here is
    /// best-effort: a failed move must not fail an already-committed save.
    private func pruneStaleFiles(in directory: URL,
                                 generation: GeneratedCommand,
                                 snapshotURL: URL?,
                                 fileManager: FileManager) {
        // Every case-folded relative path this generation produced, plus
        // the directories that contain them (a prefix stays; its stale
        // children are still pruned — "dropped lib/util.js" matters as
        // much as a dropped top-level file).
        let generatedPaths = Set(generation.files.keys
            .map { $0.lowercased() }).union(["command.json"])
        var prefixes = Set<String>()
        for path in generatedPaths {
            let components = path.components(separatedBy: "/")
            for end in 1..<components.count {
                prefixes.insert(components[0..<end].joined(separator: "/"))
            }
        }
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return }
        // resolveSymlinks on both sides: temp dirs live under /var but
        // enumerate as /private/var — mixing forms miscomputes rel paths.
        let base = directory.resolvingSymlinksInPath().path
        var stale: [String] = []
        for case let url as URL in enumerator {
            let resolved = url.resolvingSymlinksInPath().path
            // Prefix check, not just length: a symlink resolving outside
            // the command directory must not manufacture a bogus rel.
            guard resolved.hasPrefix(base + "/") else { continue }
            // Keep the exact spelling for filesystem ops — the case-folded
            // form is only for membership checks (case-sensitive volumes
            // would otherwise build a source path that doesn't exist).
            let exactRel = String(resolved.dropFirst(base.count + 1))
            let rel = exactRel.lowercased()
            if rel == "data" || rel.hasPrefix("data/")
                || rel == "history" || rel.hasPrefix("history/") {
                enumerator.skipDescendants()
                continue
            }
            if generatedPaths.contains(rel) || prefixes.contains(rel) {
                continue
            }
            stale.append(exactRel)
            // A stale directory's contents move with it — no per-child
            // re-report needed.
            enumerator.skipDescendants()
        }
        for rel in stale {
            let source = directory.appendingPathComponent(rel)
            if let snapshotURL {
                let destination = snapshotURL.appendingPathComponent(rel)
                if fileManager.fileExists(atPath: destination.path) {
                    // The snapshot already holds this path — a renamed
                    // entry was snapshotted before the writes. The snapshot
                    // copy is the recovery; the live one just goes away.
                    try? fileManager.removeItem(at: source)
                } else {
                    try? fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? fileManager.moveItem(at: source, to: destination)
                }
            } else {
                try? fileManager.removeItem(at: source)
            }
        }
    }

    /// Same rules the parser enforces: a relative path with no `..`, no
    /// backslashes, no absolute or hidden components. Internal rather than
    /// private — `MakerModel.stage` reuses it as a second gate on the way
    /// to executing a draft.
    static func isSafeRelativePath(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("/")
            && !name.hasPrefix(".")
            && !name.hasSuffix("/")
            && !name.contains("//")
            && !name.contains("\\")
            && !name.contains("/.")
            && !name.components(separatedBy: "/").contains("..")
    }

    /// `history/<yyyy-MM-dd'T'HHmmss>` — local time for human browsing;
    /// a `-2`, `-3`… suffix disambiguates two saves inside one second.
    private func uniqueSnapshotDirectory(in directory: URL,
                                         fileManager: FileManager) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: Date())
        let history = directory.appendingPathComponent("history", isDirectory: true)
        var candidate = history.appendingPathComponent(stamp, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = history.appendingPathComponent("\(stamp)-\(suffix)",
                                                       isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    // MARK: Manifest normalization

    /// Re-serializes the manifest deterministically — pretty-printed with
    /// sorted keys — and stamps `generated` provenance: the prompt that
    /// produced this revision, the model, and the bumped revision counter.
    /// Working on the JSON object (not re-encoding `CommandManifest`)
    /// preserves any extra keys the model emitted.
    private func normalizedManifest(_ json: String, revision: Int,
                                    prompt: String, model: String) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              var dictionary = object as? [String: Any] else {
            throw SaveError.manifestNotObject
        }
        dictionary["generated"] = [
            "prompt": prompt,
            "model": model,
            "revision": revision,
        ]
        var data = try JSONSerialization.data(withJSONObject: dictionary,
                                              options: [.prettyPrinted, .sortedKeys])
        // Editors and diffs expect a trailing newline.
        data.append(contentsOf: [0x0A])
        return data
    }
}
