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
    /// The query text to highlight inside the title — the matched
    /// characters render semibold so the eye finds the hit per row
    /// (Spotlight/Alfred/Raycast all do). nil disables highlighting.
    /// Highlighting only ever marks a *contiguous* occurrence: a fuzzy
    /// scatter highlights nothing rather than approximating.
    var highlight: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                titleText
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

    /// The title with its matched segment emphasized — three `Text`s
    /// concatenated so the semibold span rides the same line limit and
    /// color as the rest.
    private var titleText: Text {
        let body = typeface.font(.body)
        if let segments = Self.highlightSegments(of: highlight, in: row.title) {
            return Text(segments.before).font(body)
                + Text(segments.matched).font(typeface.font(.body, weight: .semibold))
                + Text(segments.after).font(body)
        }
        return Text(row.title).font(body)
    }

    /// Splits `title` around the first contiguous case-insensitive
    /// occurrence of `query` — the segments the highlighted title renders.
    /// nil when there is nothing to highlight: no query, a blank one, or no
    /// whole occurrence (a fuzzy-tier match marks nothing rather than
    /// guessing at scattered spans).
    static func highlightSegments(of query: String?, in title: String)
        -> (before: String, matched: String, after: String)? {
        guard let query, !query.isEmpty,
              let range = title.range(of: query, options: .caseInsensitive)
        else { return nil }
        return (String(title[..<range.lowerBound]),
                String(title[range]),
                String(title[range.upperBound...]))
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
