import Foundation

/// Recently submitted queries, most recent first — the panel's ↑-recall
/// rail. A query is worth recalling when the user submitted it (⏎ picked a
/// row), so only the controller records, never keystrokes.
///
/// Persists as one small JSON array in `UserDefaults`, like frecency.
/// Main-thread confined (the panel's UI state reads it); no lock needed.
final class QueryHistory {

    /// Storage key — version it if the schema changes.
    private static let storageKey = "PanelQueryHistory.v1"

    /// Upper bound on remembered queries; oldest entries fall off.
    private static let maxEntries = 50

    private let defaults: UserDefaults

    /// The remembered queries, most recent first.
    private(set) var entries: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A corrupted store resets rather than wedging recall — same
        // recovery as frecency.
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            entries = stored
        } else {
            entries = []
        }
    }

    /// Records `query` at the front, trimmed. Blank queries never record;
    /// a repeat of the current front is a no-op, and a non-consecutive
    /// repeat moves to the front without duplicating — re-submitting an
    /// older query must not grow the list.
    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard entries.first != trimmed else { return }
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
