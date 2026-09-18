import Foundation

/// The user's recorded consent for a command's risky permissions.
///
/// PLAN §4.3: the first run of a `shell`/`paste` command shows a
/// confirmation sheet; once allowed, the grant is remembered so the command
/// runs silently thereafter. Grants live in UserDefaults keyed by the
/// command's manifest name — app-owned state, never under `data/` where a
/// command with the `files` permission could write its own grant.
final class CommandPermissionGrants {

    /// Permissions that require explicit first-run consent. Filter-mode
    /// commands never receive these modules (JSRuntime strips them), so the
    /// check only guards action-mode runs.
    static let risky: Set<CommandManifest.Permission> = [.shell, .paste]

    /// `{commandName: [permissionRawValue]}` — unioned on each grant, so a
    /// manifest that gains a risky permission re-asks only for the new one.
    private static let defaultsKey = "commandPermissionGrants"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The command's declared risky permissions not yet granted, sorted for
    /// a stable confirmation display. An empty result means "run it".
    func ungranted(for command: Command) -> [CommandManifest.Permission] {
        let granted = grantedPermissions(for: command.name)
        return command.permissions
            .intersection(Self.risky)
            .subtracting(granted)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Records consent for `permissions`; already-granted ones are kept.
    func grant(_ permissions: [CommandManifest.Permission], for command: Command) {
        var store = loadStore()
        var granted = Set(store[command.name] ?? [])
        granted.formUnion(permissions.map(\.rawValue))
        store[command.name] = granted.sorted()
        defaults.set(store, forKey: Self.defaultsKey)
    }

    /// One-line explanation of what a risky permission lets the command do —
    /// the confirmation sheet's body copy.
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

    private func grantedPermissions(for name: String) -> Set<CommandManifest.Permission> {
        Set((loadStore()[name] ?? []).compactMap(CommandManifest.Permission.init(rawValue:)))
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
