import AppKit
import SwiftUI

/// One result line: icon, title, subtitle, with the selected row highlighted.
/// All colors arrive resolved from the host view — the row owns layout, not
/// theme decisions. Shared by `PanelView`'s results list and the detached
/// file-search window (`DetachedSearchView`).
struct ResultRowView: View {

    let row: ResultRow
    /// The resolved bitmap for `.fileURL`/`.appIcon` rows — the
    /// shared-store icon when Pict has one, else the workspace icon.
    /// Unused (nil) on `.symbol` rows.
    let iconImage: NSImage?
    let isSelected: Bool
    /// User-pinned entry — drawn as a small pin trailing the row.
    let pinned: Bool
    /// The selection fill — the theme highlight or, under adaptive accent,
    /// the icon's dominant color.
    let fill: NSColor
    let fillOpacity: Double
    let cornerRadius: Double
    let titleColor: Color
    let subtitleColor: Color
    /// The chosen typeface — title at `.body`, subtitle at `.caption`.
    let typeface: PanelTypeface
    /// Whether the selection fill bleeds a soft glow past the row (the
    /// adaptive-accent bloom).
    let glows: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(typeface.font(.body))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(typeface.font(.caption))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if pinned {
                Image(systemName: "pin.fill")
                    .font(typeface.font(.caption))
                    .foregroundStyle(subtitleColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? Color(nsColor: fill).opacity(fillOpacity) : Color.clear)
                .shadow(color: isSelected && glows
                            ? Color(nsColor: fill).opacity(0.5)
                            : .clear,
                        radius: 10)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius,
                                       style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// SF Symbols render as vectors; file/app icons arrive resolved as
    /// bitmaps, so they need explicit sizing. An empty `iconImage` is the
    /// unreachable fallback — the workspace always answers for a real path.
    @ViewBuilder
    private var icon: some View {
        switch row.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(isSelected ? titleColor : subtitleColor)
        case .fileURL, .appIcon:
            Image(nsImage: iconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}
