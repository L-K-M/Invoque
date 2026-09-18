import CryptoKit
import Foundation

/// The user's recorded consent for a command's risky permissions.
///
/// PLAN §4.3: the first run of a `shell`/`paste` command shows a
/// confirmation card; once allowed, the grant is remembered so the command
/// runs silently thereafter. Grants live in UserDefaults keyed by the
/// command's name **plus a hash of its entry file** — app-owned state,
/// never under `data/` where a command could write its own grant. The
/// content hash is the whole point: consent attaches to the code the user
/// saw, so a regenerated, replaced, or same-named command re-asks rather
/// than inheriting a grant it never earned. (The entry file is the only
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

    /// The command's declared risky permissions not yet granted, sorted for
    /// a stable confirmation display. An empty result means "run it".
    func ungranted(for command: Command) -> [CommandManifest.Permission] {
        let granted = grantedPermissions(for: grantKey(for: command))
        return command.permissions
            .intersection(Self.risky)
            .subtracting(granted)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Records consent for `permissions`; already-granted ones are kept.
    /// Older content hashes under the same name are dropped — a grant for
    /// new bytes supersedes them, keeping the store to one entry per name
    /// instead of accumulating every hash ever consented to. Reverting to
    /// the old bytes just re-asks, which is the safe direction.
    func grant(_ permissions: [CommandManifest.Permission], for command: Command) {
        var store = loadStore()
        let key = grantKey(for: command)
        let prefix = "\(command.name)@"
        // Collect first — mutating a dictionary while iterating it traps.
        let superseded = store.keys.filter { $0.hasPrefix(prefix) && $0 != key }
        superseded.forEach { store.removeValue(forKey: $0) }
        var granted = Set(store[key] ?? [])
        granted.formUnion(permissions.map(\.rawValue))
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

    /// `name@sha256(entry file, 16 hex)` — readable prefix for debugging,
    /// hash tail so identical code keeps its grant and any byte of changed
    /// code re-asks. An unreadable entry hashes as empty, which is fine:
    /// the grant check only runs for commands the runtime could load.
    private func grantKey(for command: Command) -> String {
        let entryData = (try? Data(contentsOf: command.entryURL)) ?? Data()
        let digest = SHA256.hash(data: entryData)
            .map { String(format: "%02x", $0) }.joined().prefix(16)
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
}
