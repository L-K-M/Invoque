import Foundation

/// A command directory that loaded and validated successfully.
struct Command: Equatable, Identifiable, Sendable {

    let manifest: CommandManifest
    /// The command's directory: `command.json`, the entry file, `data/`,
    /// `history/`.
    let directory: URL
    /// `manifest.entry` resolved inside `directory`. Containment is checked
    /// by manifest validation, so this never points outside the directory.
    let entryURL: URL

    /// Two roots may contain same-named commands; the directory path is the
    /// stable identity.
    var id: String { directory.path }
    var name: String { manifest.name }
    /// Permissions that survived validation — the JS bridge's allowlist.
    var permissions: Set<CommandManifest.Permission> { manifest.grantedPermissions }
    /// Scratch space the command may always write to: `fs` is scoped here
    /// and `storage.json` lives here.
    var dataDirectory: URL {
        directory.appendingPathComponent("data", isDirectory: true)
    }

    init(manifest: CommandManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory.standardizedFileURL
        let resolvedEntry = self.directory
            .appendingPathComponent(manifest.entry)
            .standardizedFileURL
        // `validate(in:)` already enforces this; the precondition is the
        // backstop for a future call site that skips validation — an entry
        // is fed to the JS bridge and executed, so it must never escape.
        // Symlinks are resolved on both sides (as validate does) so an
        // entry symlinked out of the directory can't slip the prefix check;
        // a "/" container compares against "/", not "//".
        let container = self.directory.resolvingSymlinksInPath().standardizedFileURL.path
        precondition(resolvedEntry.resolvingSymlinksInPath().standardizedFileURL.path
                        .hasPrefix(container == "/" ? "/" : container + "/"),
                     "command entry escapes its directory: \(resolvedEntry.path)")
        entryURL = resolvedEntry
    }

    // MARK: Loading

    enum LoadError: Error, Equatable, LocalizedError {
        /// No `command.json` in the directory.
        case manifestMissing
        /// `command.json` exists but could not be read.
        case manifestUnreadable

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "no command.json in directory"
            case .manifestUnreadable:
                return "command.json could not be read"
            }
        }
    }

    /// Loads `command.json` from `directory` and validates it. Throws
    /// `LoadError`, a `DecodingError`, or `CommandManifest.ValidationError`.
    init(directory: URL) throws {
        // Standardize before validating so the path `validate` checks and
        // the stored directory/entryURL are the same path.
        let directory = directory.standardizedFileURL
        let manifestURL = directory.appendingPathComponent("command.json")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: manifestURL.path, isDirectory: &isDirectory) else {
            throw LoadError.manifestMissing
        }
        guard !isDirectory.boolValue else {
            throw LoadError.manifestUnreadable
        }
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LoadError.manifestUnreadable
        }
        let manifest = try JSONDecoder().decode(CommandManifest.self, from: data)
        try manifest.validate(in: directory)
        self.init(manifest: manifest, directory: directory)
    }
}
