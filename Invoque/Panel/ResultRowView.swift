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
    /// Whether to show the source type badge — off in the detached file
    /// window, which is already contextually about files.
    var showSourceBadge: Bool = false

    /// Mouse-over feedback — a faint fill at a fraction of the selection
    /// opacity, so a pointer pick has an affordance before the click.
    /// State only; nothing animates.
    @State private var isHovered = false

    /// The query text to highlight inside the title — the matched
    /// characters render semibold so the eye finds the hit per row
    /// (Spotlight/Alfred/Raycast all do). nil disables highlighting.
    /// Highlighting only ever marks a *contiguous* occurrence: a fuzzy
    /// scatter highlights nothing rather than approximating.
    var highlight: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            sourceBadge
            icon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                titleText
                // A row with no subtitle doesn't pay for the empty line —
                // subtitle-less rows (filter output, bare commands) run
                // compact instead of uniformly tall.
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(typeface.font(.caption))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
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
                .fill(rowFill)
                .shadow(color: isSelected && glows
                            ? Color(nsColor: fill).opacity(0.5)
                            : .clear,
                        radius: 10)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius,
                                       style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// The row's background fill: the selection fill when selected, a
    /// faint version of the same color on hover, clear otherwise.
    private var rowFill: Color {
        if isSelected { return Color(nsColor: fill).opacity(fillOpacity) }
        if isHovered {
            return Color(nsColor: fill).opacity(fillOpacity * Self.hoverFillFraction)
        }
        return .clear
    }

    /// Fraction of the selection fill used for the hover affordance.
    private static let hoverFillFraction: Double = 0.45

    /// A small colored dot indicating the result's source category.
    /// Only shown for durable source types (app, command, system, file);
    /// ephemeral rows (filter, path, calc, web) are noise-free.
    @ViewBuilder
    private var sourceBadge: some View {
        if showSourceBadge, let color = sourceBadgeColor {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .frame(width: 12)
        } else {
            Color.clear.frame(width: 0)
        }
    }

    private var sourceBadgeColor: Color? {
        switch row.sourceType {
        case .app: return .blue
        case .command: return .green
        case .system: return .gray
        case .file: return .orange
        case .filter: return .yellow
        case .path, .calculator, .web, .unknown: return nil
        }
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
