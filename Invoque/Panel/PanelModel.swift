import Foundation

/// One selectable row in the launcher's results list: the display fields of
/// an `Item` plus the action picking it performs. The view never sees `Item`
/// itself — rows are the panel's presentation shape.
struct ResultRow: Identifiable, Equatable {

    let id: String
    let title: String
    let subtitle: String
    let icon: Item.Icon
    let action: Item.Action

    init(item: Item) {
        id = item.id
        title = item.title
        subtitle = item.subtitle
        icon = item.icon
        action = item.action
    }
}

/// View model for the launcher panel: query, results, and the selection
/// within them. Foundation-only so the selection logic stays unit-testable.
///
/// The search is synchronous: sources serve cached data (`AppSource` holds
/// an in-memory scan; calculator/system/web compute in microseconds), so a
/// `results(for:)` per keystroke stays on the main thread by design.
final class PanelModel: ObservableObject {

    /// Receives the selected row when the user presses ⏎ — `nil` when there
    /// are no results. The panel's owner (PanelController) performs the
    /// row's action.
    var onSubmit: ((ResultRow?) -> Void)?

    /// The search backend. Assigning re-runs the open query so late wiring
    /// (sources assembled after the model exists) still fills the list.
    var searchModel: SearchModel? {
        didSet { refreshResults() }
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults()
        }
    }

    @Published private(set) var results: [ResultRow] = [] {
        didSet {
            // A replaced list is a new result set: restart at the top row —
            // Spotlight-style — rather than keeping an index that now names
            // an unrelated row.
            selection = 0
        }
    }

    @Published var selection = 0

    /// The currently selected row, or `nil` when there are no results.
    var selectedRow: ResultRow? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    // MARK: Searching

    /// Re-runs the current query. Called on query changes and by
    /// `AppSource.onReload` — an app scan landing after the panel opened
    /// must fill the visible list without waiting for the next keystroke.
    func refreshResults() {
        results = (searchModel?.results(for: query) ?? []).map(ResultRow.init)
    }

    // MARK: State changes

    /// Prepares a fresh summon: selection back to the first row, query cleared
    /// unless the caller keeps it (the "keep query on re-show" setting).
    func reset(clearQuery: Bool) {
        if clearQuery { query = "" }
        selection = 0
    }

    /// Moves the selection by `delta` rows, wrapping at both ends.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        // Double modulo: plain `%` would go out of range for negative deltas.
        selection = ((selection + delta) % count + count) % count
    }

    /// Selects `row` directly — mouse taps land here rather than moving the
    /// index one step at a time.
    func select(_ row: ResultRow) {
        guard let index = results.firstIndex(of: row) else { return }
        selection = index
    }

    /// Hands the selected row (or `nil`, when there are no results) to
    /// `onSubmit`.
    func submit() {
        onSubmit?(selectedRow)
    }
}
