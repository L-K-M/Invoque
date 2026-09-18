import AppKit
import SwiftUI

/// The launcher panel's content: a rounded card with a search field on top, a
/// results list below, and key hints in the footer.
///
/// The search field is an `NSViewRepresentable` `NSTextField` rather than a
/// SwiftUI `TextField` + `@FocusState`: in a `.nonactivatingPanel` the panel
/// becomes key without the app activating, and SwiftUI's focus system does not
/// reliably follow that — keystrokes can end up dead while the field *looks*
/// focused. A plain `NSTextField` plus `window.makeFirstResponder(_:)` (see
/// `SearchTextField` and `PanelController.show`) is deterministic, and its
/// `doCommandBy` hook intercepts ↑/↓/⏎ before the field editor can
/// reinterpret them.
struct PanelView: View {

    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, Metrics.fieldPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            if let request = model.permissionRequest {
                PermissionRequestCard(request: request,
                                      onAllow: model.confirmPermissionRequest,
                                      onDecline: model.dismissPermissionRequest)
            } else if model.makerIsActive, let maker = model.maker {
                MakerView(model: maker, prompt: model.makerPrompt ?? "")
            } else {
                resultList
            }

            Divider().padding(.horizontal, 12)

            footer
                .padding(.horizontal, Metrics.fieldPadding)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        // Transparent margin around the card so the window's shadow has room.
        .padding(Metrics.cardInset)
    }

    // MARK: Sections

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            SearchField(
                text: $model.query,
                onUp: { model.moveSelection(by: -1) },
                onDown: { model.moveSelection(by: 1) },
                onReturn: { model.submit(commandModifier: $0) }
            )
            // The representable's intrinsic size hugs the placeholder —
            // claim the row's width so the field doesn't resize per keystroke.
            .frame(maxWidth: .infinity)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    if model.results.isEmpty {
                        // An empty query hasn't searched yet — hint instead
                        // of claiming there are no results.
                        Text(model.query.isEmpty
                             ? "Search apps, commands, or the web"
                             : "No results")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(model.results) { row in
                            ResultRowView(row: row,
                                          isSelected: model.selectedRow?.id == row.id)
                                .id(row.id)
                                .onTapGesture {
                                    model.select(row)
                                    model.submit()
                                }
                                .accessibilityAction {
                                    model.select(row)
                                    model.submit()
                                }
                        }
                    }
                }
                .padding(.horizontal, Metrics.edgePadding)
                .padding(.vertical, 8)
            }
            // Arrow-key selection must keep the highlighted row visible.
            // `.task(id:)` instead of `.onChange`: the non-deprecated
            // onChange signature requires macOS 14 and we target 13. The key
            // is the selected row's identity, not the index — a new query can
            // replace every row while the index stays the same.
            .task(id: model.selectedRow?.id) {
                guard let id = model.selectedRow?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        Text(model.permissionRequest != nil
             ? "⌘⏎ allow · esc dismiss"
             : model.makerIsActive
             ? "⏎ generate/save · esc dismiss"
             : "↑↓ navigate · ⏎ open · esc dismiss")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }
}

/// The first-run consent card for a command's risky permissions (PLAN
/// §4.3): what the command wants, spelled out per permission, then
/// Allow / Don't Run. ⌘⏎ (or the Allow button) grants; plain ⏎ is neutral.
private struct PermissionRequestCard: View {

    let request: CommandPermissionRequest
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    // The title is command-authored and could pose as a
                    // system prompt — the trusted attribution leads, the
                    // untrusted title follows it.
                    Text("Invoque command · \(request.command.name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(request.command.manifest.title)
                        .font(.headline)
                    Text("wants to:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(request.permissions, id: \.rawValue) { permission in
                Label(CommandPermissionGrants.consentLine(for: permission),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.leading, 4)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Don't Run", action: onDecline)
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Metrics.edgePadding + 6)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: -

/// Layout constants for the card and its rows.
private enum Metrics {
    static let cardInset: CGFloat = 12
    static let cornerRadius: CGFloat = 16
    static let rowCornerRadius: CGFloat = 8
    static let edgePadding: CGFloat = 10
    static let fieldPadding: CGFloat = 20
}

// MARK: -

/// One result line: icon, title, subtitle, with the selected row highlighted.
private struct ResultRowView: View {

    let row: ResultRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius,
                                       style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// SF Symbols render as vectors; file/app icons come from the
    /// workspace's icon cache as bitmaps, so they need explicit sizing.
    @ViewBuilder
    private var icon: some View {
        switch row.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(.secondary)
        case .fileURL(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .appIcon(let path):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: -

/// The search field as a plain `NSTextField` — see `PanelView`'s doc comment
/// for why not a SwiftUI `TextField`.
private struct SearchField: NSViewRepresentable {

    @Binding var text: String
    var onUp: () -> Void
    var onDown: () -> Void
    /// `true` when ⌘ was held — consent cards need ⌘⏎ so a habitual
    /// double-⏎ can't record a permanent permission grant.
    var onReturn: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = "Search"
        field.font = NSFont.systemFont(ofSize: 22)
        field.textColor = .labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        // Sync programmatic resets (query cleared on re-show) into the field.
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    // MARK: Coordinator

    /// Forwards field edits to the binding and navigation keys to the panel.
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onReturn(NSApp.currentEvent?.modifierFlags
                    .contains(.command) == true)
                return true
            default:
                // Everything else — notably `cancelOperation:` (Esc) — stays
                // with the responder chain, which reaches LauncherPanel.
                return false
            }
        }
    }
}

// MARK: -

/// The search field, which must own keyboard focus whenever the panel is
/// visible. Registers itself with the panel when it lands in a window: SwiftUI
/// may build the field only after the panel is on screen, so this hook (rather
/// than the controller alone) is what reliably captures focus on the first
/// summon. `PanelController.show` covers subsequent summons.
private final class SearchTextField: NSTextField {

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if let panel = window as? LauncherPanel {
            panel.preferredFirstResponder = self
        }
        // If the panel is already key (first summon), take focus immediately.
        // Restricted to LauncherPanel so previews or other hosts don't lose
        // their first responder to this field.
        if window is LauncherPanel, window.isKeyWindow {
            window.makeFirstResponder(self)
        }
    }
}
