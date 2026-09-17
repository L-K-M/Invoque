import Foundation

/// One selectable row in the launcher's results list.
struct ResultRow: Identifiable, Equatable {

    let id: String
    let title: String
    let subtitle: String

    /// SF Symbol name for the row's icon.
    let iconName: String
}

/// View model for the launcher panel: query, results, and the selection
/// within them. Foundation-only so the selection logic stays unit-testable.
final class PanelModel: ObservableObject {

    /// Receives the selected row when the user presses ⏎ — `nil` when there
    /// are no results. The panel's owner (PanelController) decides what
    /// happens next.
    var onSubmit: ((ResultRow?) -> Void)?

    @Published var query = ""

    // TODO: wired to SearchModel in the search-glue PR. Seeded with
    // placeholders so the panel's UI is visible and navigable until search
    // lands.
    @Published var results: [ResultRow] = [
        ResultRow(id: "placeholder.apps",
                  title: "Applications",
                  subtitle: "Search and launch apps on this Mac",
                  iconName: "square.grid.2x2"),
        ResultRow(id: "placeholder.web",
                  title: "Web Search",
                  subtitle: "Fall back to searching the web for the whole query",
                  iconName: "globe"),
    ] {
        didSet { clampSelection() }
    }

    @Published var selection = 0

    /// The currently selected row, or `nil` when there are no results.
    var selectedRow: ResultRow? {
        results.indices.contains(selection) ? results[selection] : nil
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

    /// Hands the selected row (or `nil`, when there are no results) to
    /// `onSubmit`.
    func submit() {
        onSubmit?(selectedRow)
    }

    private func clampSelection() {
        // A shrunken or emptied list must never leave the selection pointing
        // past the last row (or at a negative index).
        let upperBound = max(0, results.count - 1)
        if selection > upperBound {
            selection = upperBound
        }
    }
}
