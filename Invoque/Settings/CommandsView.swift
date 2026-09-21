import AppKit
import SwiftUI

/// The Commands settings tab (PLAN §7.3): the command inventory the
/// launcher actually loaded — title, mode, granted permissions, and the
/// directory each lives in — plus the roots they were scanned from and
/// any folders that failed to load. Read-only for now: editable roots
/// and per-command enable/disable are separate milestones; today the
/// surface exists to answer "why isn't my command in the list?".
struct CommandsView: View {

    let store: CommandStore

    /// Snapshots of the store's last scan — refreshed on appear and by
    /// the Rescan button. The store's `onChange` slot is already claimed
    /// by `CommandSource`, so this view polls deliberately instead of
    /// subscribing.
    @State private var commands: [Command] = []
    @State private var scanErrors: [CommandStore.ScanError] = []
    @State private var rescanning = false

    var body: some View {
        Form {
            commandsSection
            errorsSection
            foldersSection
        }
        .formStyle(.grouped)
        .padding()
        .task { await rescan() }
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
                        // they get the warning tint so a granted command's
                        // reach is visible at a glance (PLAN §4.3).
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
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([command.directory])
            }
            .accessibilityLabel("Reveal \(command.manifest.title) in Finder")
        }
    }

    /// A tiny capsule label — a mode or a granted permission.
    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// Granted permissions in manifest-string order for a stable row.
    private static func sortedPermissions(of command: Command) -> [CommandManifest.Permission] {
        command.permissions.sorted { $0.rawValue < $1.rawValue }
    }

    /// Reveal a root in Finder, creating it first — the commands folder
    /// doesn't exist until the first `make` saves into it, and a Reveal
    /// that silently no-ops would read as a broken button.
    private func reveal(_ root: URL) {
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// Reloads the snapshots from a fresh disk pass. `scan()` does its
    /// I/O on the caller's thread, so the pass hops off-main.
    private func rescan() async {
        rescanning = true
        defer { rescanning = false }
        let store = self.store
        // Immutable structs crossing the hop — the exemption sits on the
        // value, like HUD's font hand-off.
        nonisolated(unsafe) let snapshot = await Task.detached {
            (store.scan(), store.scanErrors)
        }.value
        commands = snapshot.0
        scanErrors = snapshot.1
    }
}
