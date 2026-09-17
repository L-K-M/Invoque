import Foundation

/// Gathers items from every source, scores them, and returns the top rows.
///
/// Source priority: calculator exact results first, then fuzzy matches
/// ordered by `FuzzyMatcher` score plus the `Frecency` boost, then the web
/// fallback last. The pins are load-bearing, not cosmetic: the web row's
/// text always contains the query, so without pinning it would score like a
/// strong prefix hit and steal Return from real matches. Calculator results
/// pin to the top for the symmetric reason: `= 4` is an exact answer, not a
/// guess, and must outrank fuzzy noise.
///
/// Empty or blank queries yield no results; what an empty panel shows is a
/// UI concern for the later panel PR, not the model's.
final class SearchModel {

    // MARK: Configuration

    /// Hard cap on returned rows. Sources can emit hundreds of apps; the
    /// panel cannot show them, and scoring already ordered the best first.
    static let maxResults = 50

    // MARK: State

    private let sources: [ItemSource]
    private let frecency: Frecency

    // MARK: Init

    init(sources: [ItemSource], frecency: Frecency) {
        self.sources = sources
        self.frecency = frecency
    }

    // MARK: Searching

    /// An item with its combined ranking score.
    private struct ScoredItem {
        let item: Item
        let score: Double
    }

    /// Ranked items for `query`, best first, at most `maxResults`. Sources
    /// receive the trimmed query. Duplicate ids (e.g. the same app found in
    /// two folders) keep only the highest score.
    func results(for query: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var calculatorHits: [Item] = []
        var webHits: [Item] = []
        var bestByID: [String: ScoredItem] = [:]

        for source in sources {
            for item in source.items(matching: trimmed) {
                if item.id.hasPrefix(Item.calculatorIDPrefix) {
                    calculatorHits.append(item)
                } else if item.id.hasPrefix(Item.webIDPrefix) {
                    webHits.append(item)
                } else if let matchScore = FuzzyMatcher.score(trimmed, candidate: item.matchText) {
                    let combined = Double(matchScore) + frecency.score(item.id)
                    if let existing = bestByID[item.id] {
                        if combined > existing.score {
                            bestByID[item.id] = ScoredItem(item: item, score: combined)
                        }
                    } else {
                        bestByID[item.id] = ScoredItem(item: item, score: combined)
                    }
                }
            }
        }

        // Sorting is not guaranteed stable, so ties break on title then id:
        // identical queries always produce identical lists.
        let ranked = bestByID.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.item.title != rhs.item.title { return lhs.item.title < rhs.item.title }
                return lhs.item.id < rhs.item.id
            }
            .map { $0.item }

        // The pinned rows get their slots first: a noisy query that fills the
        // ranked list must not push the web fallback past the cap.
        let rankedSlots = max(0, Self.maxResults - calculatorHits.count - webHits.count)
        return calculatorHits + Array(ranked.prefix(rankedSlots)) + webHits
    }

    // MARK: Selection

    /// Records that the user picked `item`, so future ties break in its
    /// favor.
    func recordSelection(_ item: Item) {
        frecency.record(item.id)
    }
}
