import AppKit
import SwiftUI

/// The Commands settings tab (PLAN §7.3): the command inventory the
/// launcher actually loaded — title, mode, declared permissions, and the
/// directory each lives in — plus the roots they were scanned from and
/// any folders that failed to load. Read-only for now: editable roots
/// and per-command enable/disable are separate milestones; today the
/// surface exists to answer "why isn't my command in the list?".
struct CommandsView: View {

    let store: CommandStore
    /// The consent ledger — a declared `shell`/`paste` is only capability
    /// until first-run consent; the badge shows which state it's in.
    let permissionGrants: CommandPermissionGrants

    /// Snapshots of the store's last scan — refreshed on appear, when the
    /// app re-activates (returning from the editor that changed a file),
    /// and by the Rescan button. The store's `onChange` slot is already
    /// claimed by `CommandSource`, so this view doesn't subscribe — a
    /// disk change while the window sits open waits for the next refresh.
    @State private var commands: [Command] = []
    @State private var scanErrors: [CommandStore.ScanError] = []
    /// Commands' ungranted risky permissions, keyed by command id —
    /// computed in `rescan`'s detached pass since `ungranted(for:)`
    /// hashes the entry file.
    @State private var pendingConsent: [String: Set<CommandManifest.Permission>] = [:]
    @State private var rescanning = false
    /// The view's own window state — app activation alone must not rescan
    /// (clicking the status item activates too); only a visible Settings
    /// window benefits from the refresh.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Form {
            commandsSection
            errorsSection
            foldersSection
        }
        .formStyle(.grouped)
        .padding()
        .task { await rescan() }
        // Editing a command then clicking back to this window is the
        // "why isn't it listed" moment — refiring on this window's
        // active-state transitions covers it, gated to the becoming-key
        // edge so activation of other windows costs no rescan. `.task(id:)`
        // rather than `.onChange`: the non-deprecated signature needs
        // macOS 14, and an `onReceive` snapshot of `controlActiveState`
        // can lag the window actually becoming key — this fires on the
        // transition itself.
        .task(id: controlActiveState) {
            guard controlActiveState == .key else { return }
            await rescan()
        }
    }

    /// The inventory, one row per command: title, mode and permission
    /// badges, and the directory the command lives in.
    private var commandsSection: some View {
        Section("Loaded Commands") {
            if commands.isEmpty {
                Text("No commands installed. Generate one with `make …`, or drop a command folder into a directory below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(commands) { command in
                commandRow(command)
            }
        }
    }

    /// Directories that looked like commands but failed to load — the
    /// answer to "why isn't my command listed" when a manifest is broken.
    @ViewBuilder
    private var errorsSection: some View {
        if !scanErrors.isEmpty {
            Section("Load Errors") {
                ForEach(scanErrors, id: \.directory) { failure in
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.directory.lastPathComponent)
                            Text(failure.error.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared
                                .activateFileViewerSelecting([failure.directory])
                        }
                        .accessibilityLabel("Reveal \(failure.directory.lastPathComponent) in Finder")
                    }
                }
            }
        }
    }

    /// The roots the store scans. Editing the set isn't surfaced yet —
    /// the rows exist so a misplaced command's home is one click away.
    private var foldersSection: some View {
        Section("Commands Folders") {
            ForEach(store.rootURLs, id: \.self) { root in
                HStack {
                    Text(root.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { reveal(root) }
                }
            }
            HStack {
                Button("Rescan") { Task { await rescan() } }
                    .disabled(rescanning)
                if rescanning {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Consented permissions are re-asked when a command's code or manifest changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commandRow(_ command: Command) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(command.manifest.title)
                    badge(command.manifest.mode.rawValue, tint: .secondary)
                    ForEach(Self.sortedPermissions(of: command), id: \.self) { permission in
                        // shell/paste are the consent-gated capabilities —
                        // the warning tint marks declared reach; the
                        // consent note below says whether the user already
                        // allowed it (PLAN §4.3).
                        badge(permission.rawValue,
                              tint: CommandPermissionGrants.risky.contains(permission)
                                  ? .orange : .secondary)
                    }
                }
                Text(command.directory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = consentNote(for: command) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([command.directory])
            }
            .accessibilityLabel("Reveal \(command.manifest.title) in Finder")
        }
    }

    /// The consent state of a command's risky permissions, e.g.
    /// "shell · asks on first run" — nil when it declares none.
    private func consentNote(for command: Command) -> String? {
        let risky = command.permissions
            .intersection(CommandPermissionGrants.risky)
            .sorted { $0.rawValue < $1.rawValue }
        guard !risky.isEmpty else { return nil }
        let pending = pendingConsent[command.id] ?? []
        return risky.map {
            pending.contains($0)
                ? "\($0.rawValue) · asks on first run"
                : "\($0.rawValue) · consented"
        }.joined(separator: ", ")
    }

    /// A tiny capsule label — a mode or a declared permission.
    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// Declared permissions in manifest-string order for a stable row.
    private static func sortedPermissions(of command: Command) -> [CommandManifest.Permission] {
        command.permissions.sorted { $0.rawValue < $1.rawValue }
    }

    /// Reveal a root in Finder, creating it first — the commands folder
    /// doesn't exist until the first `make` saves into it, and a Reveal
    /// that silently no-ops would read as a broken button.
    private func reveal(_ root: URL) {
        do {
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: true)
        } catch {
            HUD.show("Couldn't create \(root.lastPathComponent) — \(error.localizedDescription)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// Reloads the snapshots from a fresh disk pass. `scan()` does its
    /// I/O on the caller's thread, so the pass hops off-main — where the
    /// consent check's per-command entry-file hashing belongs too.
    private func rescan() async {
        // The flag doubles as a reentrancy guard — an activation refresh
        // can land while a Rescan click's pass is still on the wire.
        guard !rescanning else { return }
        rescanning = true
        defer { rescanning = false }
        let store = self.store
        let grants = permissionGrants
        let outcome = await Task.detached {
            let scan = store.scan()
            var pending: [String: Set<CommandManifest.Permission>] = [:]
            for command in scan.commands {
                let ungranted = Set(grants.ungranted(for: command))
                if !ungranted.isEmpty { pending[command.id] = ungranted }
            }
            return (scan, pending)
        }.value
        commands = outcome.0.commands
        scanErrors = outcome.0.errors
        pendingConsent = outcome.1
    }
}
