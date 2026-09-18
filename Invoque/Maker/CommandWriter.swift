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

        var errorDescription: String? {
            switch self {
            case .manifestNotObject:
                return "command.json isn't a JSON object"
            case .unsafeFileName(let name):
                return "refusing to write '\(name)' — not a safe relative path"
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
              manifest: CommandManifest,
              prompt: String,
              model: String,
              fileManager: FileManager = .default) throws -> URL {
        // Last-line defense: re-run the structural checks so an unsafe
        // `name`/`entry` can't reach the filesystem even if a caller skipped
        // the validator. The slug rule means `name` cannot traverse.
        try manifest.validateStructure()
        let directory = rootURL.appendingPathComponent(manifest.name, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("command.json")

        let previousRevision = try snapshotExisting(in: directory,
                                                    fileManager: fileManager)
        let manifestData = try normalizedManifest(generation.manifestJSON,
                                                  revision: previousRevision + 1,
                                                  prompt: prompt, model: model)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifestData.write(to: manifestURL, options: .atomic)
        for (name, contents) in generation.files where name != "command.json" {
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
    /// backslashes, no absolute or hidden components.
    private static func isSafeRelativePath(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("/")
            && !name.hasPrefix(".")
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
