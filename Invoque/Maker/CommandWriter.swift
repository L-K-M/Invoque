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
        for name in generation.files.keys {
            let firstComponent = name.components(separatedBy: "/")
                .first?.lowercased()
            guard Self.isSafeRelativePath(name),
                  firstComponent != "data", firstComponent != "history",
                  name == "command.json" || name.lowercased() != "command.json" else {
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

        let previousRevision = try snapshotExisting(in: directory,
                                                    fileManager: fileManager)
        let manifestData = try normalizedManifest(generation.manifestJSON,
                                                  revision: previousRevision + 1,
                                                  prompt: prompt, model: model)

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
        // `data/` always exists so `invoque.fs`/`storage` have their scope —
        // it stays empty until the command itself writes.
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true)
        // The manifest is the commit point: written last, a failure above
        // leaves the previous command.json describing a complete command —
        // a mid-save rescan sees old manifest + new files, still loadable.
        try manifestData.write(to: manifestURL, options: .atomic)
        return directory
    }

    // MARK: History

    /// If `directory` already holds a command, copies its `command.json` and
    /// entry file into `history/<timestamp>/` and returns its previous
    /// revision (0 for a fresh command). The snapshot happens before any
    /// write, so a failed save leaves the old command untouched.
    private func snapshotExisting(in directory: URL,
                                  fileManager: FileManager) throws -> Int {
        let manifestURL = directory.appendingPathComponent("command.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return 0 }

        // The previous entry name comes from the previous manifest — usually
        // "main.js", but a hand-edited command may differ. An undecodable old
        // manifest still snapshots command.json alone.
        let oldManifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(CommandManifest.self, from: $0) }
        let previousRevision = oldManifest?.generated?.revision ?? 0

        let snapshot = uniqueSnapshotDirectory(in: directory, fileManager: fileManager)
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        var names = ["command.json"]
        if let oldEntry = oldManifest?.entry { names.append(oldEntry) }
        for name in names {
            guard Self.isSafeRelativePath(name) else { continue }
            let source = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = snapshot.appendingPathComponent(name)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        }
        return previousRevision
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
