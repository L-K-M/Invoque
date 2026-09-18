import CryptoKit
import Foundation

/// The user's recorded consent for a command's risky permissions.
///
/// PLAN §4.3: the first run of a `shell`/`paste` command shows a
/// confirmation card; once allowed, the grant is remembered so the command
/// runs silently thereafter. Grants live in UserDefaults keyed by the
/// command's name **plus a hash of its entry file** — kept out of `data/`
/// so commands can't write their own grant through sanctioned modules.
/// (Not tamper-proof: UserDefaults is user-writable, so a command already
/// granted `shell` could forge keys — moot, since `shell` is already
/// arbitrary code with full user privileges.) The content hash is the
/// whole point: consent attaches to the code the user saw, so a
/// regenerated, replaced, or same-named command re-asks rather than
/// inheriting a grant it never earned. (The entry file is the only
/// executable surface — nothing can `require` extra files. Manifest perm
/// growth is caught separately by the declared∩risky intersection.)
final class CommandPermissionGrants {

    /// Permissions that require explicit first-run consent. Filter-mode
    /// commands never receive these modules (JSRuntime strips them), so the
    /// check only guards action-mode runs.
    static let risky: Set<CommandManifest.Permission> = [.shell, .paste]

    /// `{grantKey: [permissionRawValue]}` — unioned on each grant, so a
    /// manifest that gains a risky permission re-asks only for the new one.
    private static let defaultsKey = "commandPermissionGrants"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns a paused-run request if the command has ungranted risky
    /// permissions, nil when it may run. The entry-file digest is captured
    /// once, here, so the grant later recorded for the request binds to the
    /// bytes the user was shown — if the file changes before Allow lands,
    /// the resumed run's fresh check sees a different key and re-asks.
    func consentRequest(for command: Command, args: [String]) -> CommandPermissionRequest? {
        let key = grantKey(for: command)
        let pending = command.permissions
            .intersection(Self.risky)
            .subtracting(grantedPermissions(for: key))
            .sorted { $0.rawValue < $1.rawValue }
        guard !pending.isEmpty else { return nil }
        return CommandPermissionRequest(command: command, args: args,
                                        permissions: pending, grantKey: key)
    }

    /// The command's declared risky permissions not yet granted, sorted for
    /// a stable confirmation display. An empty result means "run it".
    func ungranted(for command: Command) -> [CommandManifest.Permission] {
        consentRequest(for: command, args: [])?.permissions ?? []
    }

    /// Records consent for a request's permissions; already-granted ones
    /// are kept. The grant lands under the key captured when the request
    /// was built — never a re-hash of whatever the file holds now, which
    /// would consent to bytes the user never saw. Older content hashes
    /// under the same name are dropped — a grant for new bytes supersedes
    /// them, keeping the store to one entry per name instead of
    /// accumulating every hash ever consented to. Reverting to the old
    /// bytes just re-asks, which is the safe direction.
    func grant(_ request: CommandPermissionRequest) {
        var store = loadStore()
        let key = request.grantKey
        let prefix = "\(request.command.name)@"
        // Collect first — mutating a dictionary while iterating it traps.
        // "@" appears exactly once per key: command names are slug-validated
        // (`[a-z0-9][a-z0-9_-]*`, CommandManifest.validateStructure) and the
        // digest is hex, so the prefix can only match this command's hashes —
        // an "a@b"-named command is rejected before it can run.
        let superseded = store.keys.filter { $0.hasPrefix(prefix) && $0 != key }
        superseded.forEach { store.removeValue(forKey: $0) }
        var granted = Set(store[key] ?? [])
        granted.formUnion(request.permissions.map(\.rawValue))
        store[key] = granted.sorted()
        defaults.set(store, forKey: Self.defaultsKey)
    }

    /// One-line explanation of what a risky permission lets the command do —
    /// the confirmation card's body copy.
    static func consentLine(for permission: CommandManifest.Permission) -> String {
        switch permission {
        case .shell:
            return "Run shell commands on this Mac via /bin/sh"
        case .paste:
            return "Simulate keystrokes (requires Accessibility access)"
        default:
            return permission.rawValue
        }
    }

    /// `name@sha256(entry file)` — readable prefix for debugging, hash
    /// tail so identical code keeps its grant and any byte of changed code
    /// re-asks. The digest is full-length: a truncated one would let a
    /// crafted file inherit a grant under ~2^32 hash evaluations. An
    /// unreadable entry hashes as empty, which is fine: the grant check
    /// only runs for commands the runtime could load.
    private func grantKey(for command: Command) -> String {
        let entryData = (try? Data(contentsOf: command.entryURL)) ?? Data()
        let digest = SHA256.hash(data: entryData)
            .map { String(format: "%02x", $0) }.joined()
        return "\(command.name)@\(digest)"
    }

    private func grantedPermissions(for key: String) -> Set<CommandManifest.Permission> {
        Set((loadStore()[key] ?? []).compactMap(CommandManifest.Permission.init(rawValue:)))
    }

    private func loadStore() -> [String: [String]] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
    }
}

/// A command run paused for first-run consent — carries everything needed
/// to resume it once the user allows.
struct CommandPermissionRequest {
    let command: Command
    let args: [String]
    /// The ungranted risky permissions being asked about, sorted for display.
    let permissions: [CommandManifest.Permission]
    /// Entry-file digest captured when the prompt was built — the grant is
    /// recorded under this key so consent binds to the bytes the user saw,
    /// not whatever the file holds when Allow lands.
    let grantKey: String
}
