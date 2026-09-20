import Foundation

/// Gathers items from every source, ranks them, and returns the top rows.
///
/// Source priority: `path:`/`calc:` pins first, then the user's pinned
/// entries, then ranked matches, then the web fallback last. Ranked
/// ordering is class-first — an exact prefix beats an infix beats a fuzzy
/// subsequence — then shorter match text wins inside a class, then
/// frecency, alignment score, and title/id tie-break in that order. The
/// pins are load-bearing, not cosmetic: the web row's text always
/// contains the query, so without pinning it would score like a strong
/// prefix hit and steal Return from real matches. Calculator results pin
/// to the top for the symmetric reason: `= 4` is an exact answer, not a
/// guess, and must outrank fuzzy noise.
///
/// `entryRules` carries the user's pins and blocks: pinned entries form a
/// band between the functional head pins and the ranked middle (they must
/// still match — a pin boosts, it doesn't conjure), and blocked ids are
/// dropped before matching, absolutely.
///
/// Empty or blank queries yield no results; what an empty panel shows is a
/// UI concern for the later panel PR, not the model's.
final class SearchModel {

    // MARK: Configuration

    /// Hard cap on returned rows. Sources can emit hundreds of apps; the
    /// panel cannot show them, and scoring already ordered the best first.
    static let maxResults = 50

    /// The normalization `results(for:)` applies before matching. Kept as
    /// the single implementation because `PanelModel`'s stability merge
    /// re-matches rows against the same form — a divergent trim there
    /// would let survivors outlive the model's own filter.
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: State

    private let sources: [ItemSource]
    private let frecency: Frecency
    /// The user's pin/block sets, read live per query — a Settings edit
    /// applies to the next keystroke without rewiring the model.
    private let entryRules: EntryRules

    // MARK: Init

    init(sources: [ItemSource], frecency: Frecency,
         entryRules: EntryRules = EntryRules()) {
        self.sources = sources
        self.frecency = frecency
        self.entryRules = entryRules
    }

    // MARK: Searching

    /// An item with its match classification and frecency boost.
    private struct ScoredItem {
        let item: Item
        let match: FuzzyMatcher.Match
        let boost: Double
        /// `matchText.count`, hoisted: `String.count` walks graphemes, so
        /// it must not run twice per sort comparison.
        let matchLength: Int
    }

    /// Whether `lhs` sorts before `rhs`: match tier first (exact prefix,
    /// then infix, then fuzzy), then the shorter matched text, then the
    /// frecency boost — a frequent pick wins an otherwise-equal match —
    /// then the alignment score as the last quality signal, then title and
    /// id for a total order.
    private static func outranks(_ lhs: ScoredItem, over rhs: ScoredItem) -> Bool {
        if lhs.match.tier != rhs.match.tier {
            return lhs.match.tier < rhs.match.tier
        }
        if lhs.matchLength != rhs.matchLength {
            return lhs.matchLength < rhs.matchLength
        }
        if lhs.boost != rhs.boost { return lhs.boost > rhs.boost }
        if lhs.match.score != rhs.match.score {
            return lhs.match.score > rhs.match.score
        }
        if lhs.item.title != rhs.item.title {
            return lhs.item.title < rhs.item.title
        }
        return lhs.item.id < rhs.item.id
    }

    /// Ranked items for `query`, best first, at most `maxResults`. Sources
    /// receive the trimmed query. Duplicate ids (e.g. the same app found in
    /// two folders) keep only the better-ranked copy.
    func results(for query: String) -> [Item] {
        let trimmed = Self.normalizedQuery(query)
        guard !trimmed.isEmpty else { return [] }

        var pathHits: [Item] = []
        var calculatorHits: [Item] = []
        var webHits: [Item] = []
        // Pinned rows never pass through `bestByID`, so they get their own
        // dedupe — a misbehaving source emitting the same namespaced id
        // twice must not produce two rows.
        var pinnedIDs = Set<String>()
        var bestByID: [String: ScoredItem] = [:]
        let rules = entryRules

        for source in sources {
            for item in source.items(matching: trimmed) {
                // Block is absolute — ahead of even the pin checks, so a
                // stored `path:`/`web:`/`calc:` id honors "never show" too
                // (the UI can't produce those, but a hand edit can).
                if rules.isBlocked(item.id) { continue }
                if item.id.hasPrefix(Item.pathIDPrefix) {
                    guard pinnedIDs.insert(item.id).inserted else { continue }
                    pathHits.append(item)
                } else if item.id.hasPrefix(Item.calculatorIDPrefix) {
                    guard pinnedIDs.insert(item.id).inserted else { continue }
                    calculatorHits.append(item)
                } else if item.id.hasPrefix(Item.webIDPrefix) {
                    guard pinnedIDs.insert(item.id).inserted else { continue }
                    webHits.append(item)
                } else if let match = FuzzyMatcher.match(trimmed, candidate: item.matchText) {
                    let scored = ScoredItem(item: item, match: match,
                                            boost: frecency.score(item.id),
                                            matchLength: item.matchText.count)
                    if let existing = bestByID[item.id],
                       !Self.outranks(scored, over: existing) { continue }
                    bestByID[item.id] = scored
                }
            }
        }

        // Sorting is not guaranteed stable, so the comparator ends on title
        // then id: identical queries always produce identical lists.
        let ranked = bestByID.values
            .sorted { Self.outranks($0, over: $1) }
            .map { $0.item }

        // Pinned entries form a band under the functional head pins:
        // matched and rank-ordered like everything else (the filter
        // preserves that order), just always above unpinned matches. The
        // band is capped: a screenful of matching pins must not evict the
        // web fallback and every ranked match — pins past the cap rejoin
        // the ranked pool in their natural order instead.
        let bandCap = max(0, Self.maxResults - pathHits.count
            - calculatorHits.count - webHits.count - 1)
        let pinnedBand = Array(ranked.filter { rules.isPinned($0.id) }
            .prefix(bandCap))
        let bandIDs = Set(pinnedBand.map(\.id))
        let unpinned = ranked.filter { !bandIDs.contains($0.id) }

        // The pinned rows get their slots first: a noisy query that fills the
        // ranked list must not push the web fallback past the cap. The outer
        // clamp keeps the `maxResults` contract even if the pinned sources
        // alone would overflow it (trailing web rows go first). `path:` rows
        // lead — a typed address is a direct intent, ahead of the calculator.
        let pinnedCount = pathHits.count + calculatorHits.count
            + pinnedBand.count + webHits.count
        let rankedSlots = max(0, Self.maxResults - pinnedCount)
        return Array((pathHits + calculatorHits + pinnedBand
            + Array(unpinned.prefix(rankedSlots)) + webHits)
            .prefix(Self.maxResults))
    }

    // MARK: Selection

    /// Records that the user picked `item`, so future ties break in its
    /// favor. `web:` and `calc:` ids embed the raw query, are pinned
    /// (never fuzzy-scored), and can therefore never be ranked by frecency
    /// — recording them would persist queries for nothing and gradually
    /// evict real history from the capped table.
    func recordSelection(_ item: Item) {
        recordSelection(itemID: item.id)
    }

    /// `recordSelection` by id alone — the panel's rows carry the id, not
    /// the whole `Item`.
    func recordSelection(itemID: String) {
        // Opt-in: only durable, user-meaningful namespaces train frecency.
        // Transient ids (web/calc query rows, per-keystroke filter rows)
        // would persist meaningless keys and slowly evict real history.
        let eligible = [Item.appIDPrefix, Item.commandIDPrefix, Item.systemIDPrefix]
        guard eligible.contains(where: { itemID.hasPrefix($0) }) else { return }
        frecency.record(itemID)
    }
}
