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

            resultList

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
                onReturn: { model.submit() }
            )
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    if model.results.isEmpty {
                        Text("No results")
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
                        }
                    }
                }
                .padding(.horizontal, Metrics.edgePadding)
                .padding(.vertical, 8)
            }
            // Arrow-key selection must keep the highlighted row visible.
            // `.task(id:)` instead of `.onChange`: the non-deprecated
            // onChange signature requires macOS 14 and we target 13.
            .task(id: model.selection) {
                guard let id = model.selectedRow?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        Text("↑↓ navigate · ⏎ open · esc dismiss")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }
}

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
            Image(systemName: row.iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
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
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: -

/// The search field as a plain `NSTextField` — see `PanelView`'s doc comment
/// for why not a SwiftUI `TextField`.
private struct SearchField: NSViewRepresentable {

    @Binding var text: String
    var onUp: () -> Void
    var onDown: () -> Void
    var onReturn: () -> Void

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
                parent.onReturn()
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
