import AppKit
import PictKit
import SwiftUI

/// The detached file-search window's content: a read-only header echoing
/// the handed-off query (plus a spinner while the walk is live), the
/// streaming results list, and key hints in the footer.
///
/// This is a regular window, not the themed launcher card — labels stay
/// adaptive and the selection composites over the window background
/// rather than a material. `ResultRowView` and the icon/selection
/// resolution are shared with `PanelView`; the helpers below are the
/// window-context twins of that file's private ones.
struct DetachedSearchView: View {

    @ObservedObject var model: DetachedSearchModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().padding(.horizontal, 12)

            resultList

            Divider().padding(.horizontal, 12)

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 480, minHeight: 300)
    }

    // MARK: Theme

    /// The configured highlight, or the system accent when the hex can't
    /// parse — `PanelView.themeHighlight`'s twin.
    private var themeHighlight: NSColor {
        NSColor(hex: preferences.highlightHex) ?? .controlAccentColor
    }

    /// The selection fill for a row — the icon's dominant color under
    /// adaptive accent, else the theme highlight.
    private func selectionFill(for image: NSImage?, key: String?) -> NSColor {
        if preferences.adaptiveAccent,
           let accent = AdaptiveAccent.color(for: image, key: key) {
            return accent
        }
        return themeHighlight
    }

    /// Text over the composited selection fill — the base here is the
    /// plain window background (no themed material underneath).
    private func selectedForeground(fill: NSColor) -> Color {
        Color.readableForeground(
            on: fill.composited(alpha: preferences.highlightOpacity,
                                over: .windowBackgroundColor))
    }

    /// The bitmap to draw for an icon — `PanelView.iconImage`'s twin:
    /// the shared-store resolution when Pict has one, else the workspace
    /// icon. `nil` only for `.symbol` rows, which draw vectors.
    private func iconImage(for icon: Item.Icon) -> NSImage? {
        guard let path = icon.backingPath else { return nil }
        return icon.pictTarget.flatMap { model.iconResolver?($0) }
            ?? NSWorkspace.shared.icon(forFile: path)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(model.query)
                .font(preferences.panelTypeface.font(.title3))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.isPending {
                Spacer(minLength: 8)
                ProgressView()
                    .controlSize(.small)
                Text("Searching…")
                    .font(preferences.panelTypeface.font(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    if model.rows.isEmpty {
                        Text(model.isPending
                             ? "Searching files…"
                             : "No matching files")
                            .font(preferences.panelTypeface.font(.callout))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(model.rows) { row in
                            let isSelected = model.selectedRow?.id == row.id
                            let image = iconImage(for: row.icon)
                            let fill = isSelected
                                ? selectionFill(for: image, key: row.icon.backingPath)
                                : themeHighlight
                            let rowView = ResultRowView(row: row, iconImage: image,
                                          isSelected: isSelected,
                                          pinned: model.isPinned(row),
                                          fill: fill,
                                          fillOpacity: preferences.highlightOpacity,
                                          cornerRadius: preferences.highlightCornerRadius,
                                          titleColor: isSelected
                                              ? selectedForeground(fill: fill) : .primary,
                                          subtitleColor: isSelected
                                              ? selectedForeground(fill: fill).opacity(0.75)
                                              : .secondary,
                                          typeface: preferences.panelTypeface,
                                          glows: isSelected && preferences.adaptiveAccent)
                                .id(row.id)
                                .onTapGesture {
                                    model.select(row)
                                    model.submit()
                                }
                            if model.canManage(row) {
                                rowView.contextMenu { entryMenuItems(for: row) }
                            } else {
                                rowView
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            // Arrow-key selection must keep the highlighted row visible —
            // the same `.task(id:)` trick `PanelView` uses (macOS 13 has
            // no non-deprecated onChange).
            .task(id: model.selectedRow?.id) {
                guard let id = model.selectedRow?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(model.isPending
                 ? "Searching…"
                 : "\(model.rows.count) \(model.rows.count == 1 ? "match" : "matches")")
            Spacer()
            Text(footerHint)
        }
        .font(preferences.panelTypeface.font(.caption))
        .foregroundStyle(.tertiary)
    }

    /// The footer's key hints — pin/block chords appear only while the
    /// selection is a manageable entry, matching the panel's rule.
    private var footerHint: String {
        let manage = model.selectedRow.map(model.canManage) == true
            ? " · ⌘P pin · ⌘B block" : ""
        return "⏎ open · ⌘⏎ reveal in Finder" + manage + " · esc close"
    }

    /// The pin/block menu for one row — the panel's `entryMenuItems` twin.
    @ViewBuilder
    private func entryMenuItems(for row: ResultRow) -> some View {
        Button(model.isPinned(row) ? "Unpin" : "Pin") {
            if let toast = model.togglePin(on: row) {
                HUD.show(toast, typeface: preferences.panelTypeface)
            }
        }
        Button("Block", role: .destructive) {
            if let toast = model.toggleBlock(on: row) {
                HUD.show(toast, typeface: preferences.panelTypeface)
            }
        }
    }
}
