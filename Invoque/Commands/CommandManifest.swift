import Foundation

/// A command's `command.json`, decoded and validated.
///
/// One directory per command (see `Command`); this type models only the
/// manifest file itself. Decoding is tolerant — most fields fall back to the
/// schema's default — so a minimal manifest still loads far enough to produce
/// a useful validation error.
struct CommandManifest: Codable, Equatable {

    /// The only manifest schema this build understands.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// Directory-safe identifier, unique within a commands root.
    let name: String
    let title: String
    let description: String?
    /// How the entry file is executed. Only `.js` exists today; `exec`
    /// (shebang subprocess) is designed-for but post-v1 (PLAN §4.1).
    let runtime: Runtime
    /// Entry file path relative to the command directory, e.g. "main.js".
    let entry: String
    let mode: Mode
    let arguments: [Argument]
    let keywords: [String]
    let icon: String?
    /// Permission strings exactly as declared. Stored verbatim so `validate`
    /// can name the unknown ones — a mistyped permission should produce a
    /// precise error, not a generic "corrupted data" decode failure.
    let permissions: [String]
    /// Provenance written by the `make` command; nil for hand-written commands.
    let generated: GeneratedInfo?

    // MARK: Schema types

    enum Runtime: String, Codable {
        case js
    }

    enum Mode: String, Codable {
        /// Run once; the return value (title or item list) is the output.
        case action
        /// Re-run per keystroke; the return value is the result list.
        case filter
    }

    /// The v1 capability set. Raw values are the manifest strings.
    enum Permission: String, Codable {
        case clipboardRead = "clipboard.read"
        case clipboardWrite = "clipboard.write"
        case network
        case files
        case apps
        case open
        case paste
        case shell
        case notification
    }

    struct Argument: Codable, Equatable {
        let name: String
        /// Free-form ("text" today); interpreted by whoever renders the field.
        let type: String
        let optional: Bool

        private enum CodingKeys: String, CodingKey {
            case name, type, optional
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
            optional = try container.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        }
    }

    /// Provenance for LLM-written commands (PLAN §6): the originating prompt,
    /// the model that produced it, and a revision counter for `history/`.
    struct GeneratedInfo: Codable, Equatable {
        let prompt: String?
        let model: String?
        let revision: Int?
    }

    // MARK: Decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, title, description, runtime, entry, mode
        case arguments, keywords, icon, permissions, generated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        runtime = try container.decodeIfPresent(Runtime.self, forKey: .runtime) ?? .js
        entry = try container.decodeIfPresent(String.self, forKey: .entry) ?? "main.js"
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .action
        arguments = try container.decodeIfPresent([Argument].self, forKey: .arguments) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        generated = try container.decodeIfPresent(GeneratedInfo.self, forKey: .generated)
    }

    // MARK: Validation

    /// Errors that make a command directory unloadable.
    enum ValidationError: Error, Equatable, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case invalidName(String)
        case unknownPermissions([String])
        case entryEscapesDirectory(String)
        case entryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "unsupported schemaVersion \(version) (expected \(CommandManifest.currentSchemaVersion))"
            case .invalidName(let name):
                return "invalid command name '\(name)' — expected a lowercase slug like 'format-json'"
            case .unknownPermissions(let permissions):
                return "unknown permissions: \(permissions.sorted().joined(separator: ", "))"
            case .entryEscapesDirectory(let entry):
                return "entry '\(entry)' resolves outside the command directory"
            case .entryNotFound(let entry):
                return "entry file '\(entry)' not found"
            }
        }
    }

    /// Lowercase slug — the name doubles as a directory-unique identifier.
    /// `\A`/`\z` rather than `^`/`$`: ICU's `$` still matches before a
    /// trailing newline, which would let "format-json\n" slip through.
    private static let namePattern = "\\A[a-z0-9][a-z0-9_-]*\\z"

    /// Declared permissions this build recognizes. Only meaningful after a
    /// successful `validate` — unknown values are dropped silently here.
    var grantedPermissions: Set<Permission> {
        Set(permissions.compactMap(Permission.init(rawValue:)))
    }

    /// The checks `validate(in:)` can make without a directory: schema
    /// version, name shape, known permissions, and that `entry` is a relative
    /// path that stays inside the command directory lexically. The Maker's
    /// validator uses this on a manifest that exists only as generated text —
    /// the stronger symlink-aware containment and existence checks still
    /// happen in `validate(in:)` once the files are on disk.
    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else {
            throw ValidationError.invalidName(name)
        }
        let unknown = permissions.filter { Permission(rawValue: $0) == nil }
        guard unknown.isEmpty else {
            throw ValidationError.unknownPermissions(unknown)
        }
        guard !entry.isEmpty else {
            throw ValidationError.entryNotFound(entry)
        }
        // Lexical containment: an absolute entry, or one whose standardized
        // form climbs out of any would-be directory, is an escape. The
        // dir-based check in `validate(in:)` additionally resolves symlinks.
        guard !entry.hasPrefix("/") else {
            throw ValidationError.entryEscapesDirectory(entry)
        }
        let probe = URL(fileURLWithPath: "/_invoque_root", isDirectory: true)
        let resolved = probe.appendingPathComponent(entry).standardizedFileURL
        guard resolved.path.hasPrefix(probe.path + "/") else {
            throw ValidationError.entryEscapesDirectory(entry)
        }
    }

    /// Checks everything decoding cannot: schema version, name shape, known
    /// permissions, and that the entry file exists inside `directory`.
    func validate(in directory: URL, fileManager: FileManager = .default) throws {
        try validateStructure()
        // The entry is read and executed, so a "../" escape would run an
        // arbitrary file outside the command directory. Standardizing both
        // paths resolves ".." segments lexically; resolving symlinks too
        // closes the hole where the command directory (or an ancestor of the
        // entry) is itself a symlink pointing elsewhere.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let entryURL = root.appendingPathComponent(entry)
            .resolvingSymlinksInPath().standardizedFileURL
        guard entryURL.path.hasPrefix(root.path + "/") else {
            throw ValidationError.entryEscapesDirectory(entry)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ValidationError.entryNotFound(entry)
        }
    }
}
