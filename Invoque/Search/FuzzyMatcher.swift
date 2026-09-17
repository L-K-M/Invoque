import Foundation

/// fzf-style subsequence scorer: pure, deterministic, and cheap enough to run
/// once per item per keystroke.
///
/// `score("saf", candidate: "Safari")` is high (exact prefix, tight run);
/// `score("sfr", candidate: "Safari")` is lower (same letters, gapped);
/// `score("xyz", candidate: "Safari")` is `nil` (not a subsequence).
enum FuzzyMatcher {

    // MARK: Scoring weights

    /// Points per matched character: every alignment starts here.
    private static let basePoints = 10
    /// Bonus when the match continues the previous run (`saf` in `Safari`).
    private static let consecutiveBonus = 20
    /// Bonus when the match opens a word: position 0, after a separator, or
    /// on a camelCase hump (`Preferences` in `System Preferences`).
    private static let wordStartBonus = 12
    /// Bonus when the candidate starts with the whole query: usually what
    /// the user meant.
    private static let prefixBonus = 25
    /// Bonus for same letter, same case, so `Safari` beats `safari`.
    private static let caseBonus = 2
    /// Cost per skipped character between matches: gaps hurt.
    private static let gapPenalty = 2
    /// Length divisor: one point off per four candidate characters, so short
    /// candidates win near-ties (`Mail` beats `Mailmate` for `mail`).
    private static let lengthPenaltyDivisor = 4

    /// Characters that open a new matchable word.
    private static let separators: Set<Character> = [" ", "-", "_", ".", "/", "\\", "(", "[", "{"]

    // MARK: Scoring

    /// Scores `query` against `candidate`, or `nil` when `query` is not a
    /// case-insensitive subsequence of `candidate`. Empty queries match
    /// nothing: `SearchModel` decides what an empty panel shows.
    ///
    /// Scoring table (higher wins):
    ///
    /// | Component | Points |
    /// |---|---|
    /// | Each matched character | +10 |
    /// | Consecutive run (adjacent to the previous match) | +20 |
    /// | Word start (position 0, after a separator, camelCase hump) | +12 |
    /// | Candidate starts with the whole query | +25 |
    /// | Same case on a matched character | +2 |
    /// | Each skipped character between matches | -2 |
    /// | Candidate length | -1 per 4 characters |
    ///
    /// Matching is greedy left-to-right in a single pass over the candidate;
    /// the only allocations are lowercased copies of the inputs, so the
    /// per-keystroke cost stays flat.
    static func score(_ query: String, candidate: String) -> Int? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }

        let queryChars = Array(query.lowercased())
        let loweredCandidate = Array(candidate.lowercased())
        let rawQuery = Array(query)
        let rawCandidate = Array(candidate)
        // `lowercased()` can reshape exotic graphemes; without a 1:1 mapping
        // the camelCase check below would misalign, so it is skipped then.
        let shapesMatch = rawCandidate.count == loweredCandidate.count

        var total = 0
        var searchFrom = 0
        var previousMatch: Int?
        var queryIndex = 0

        for wanted in queryChars {
            var found: Int?
            var cursor = searchFrom
            while cursor < loweredCandidate.count {
                if loweredCandidate[cursor] == wanted {
                    found = cursor
                    break
                }
                cursor += 1
            }
            guard let matchAt = found else { return nil }

            total += Self.basePoints
            if previousMatch == matchAt - 1 {
                total += Self.consecutiveBonus
            }
            if Self.isWordStart(matchAt, lowered: loweredCandidate, raw: rawCandidate, shapesMatch: shapesMatch) {
                total += Self.wordStartBonus
            }
            if queryIndex < rawQuery.count, matchAt < rawCandidate.count,
               rawQuery[queryIndex] == rawCandidate[matchAt] {
                total += Self.caseBonus
            }
            total -= Self.gapPenalty * (matchAt - searchFrom)

            searchFrom = matchAt + 1
            previousMatch = matchAt
            queryIndex += 1
        }

        if loweredCandidate.count >= queryChars.count,
           loweredCandidate.prefix(queryChars.count).elementsEqual(queryChars) {
            total += Self.prefixBonus
        }
        total -= loweredCandidate.count / Self.lengthPenaltyDivisor
        return total
    }

    // MARK: Helpers

    /// Whether `index` opens a word: the first character, anything after a
    /// separator, or a camelCase hump (lowercase followed by uppercase).
    private static func isWordStart(_ index: Int, lowered: [Character], raw: [Character], shapesMatch: Bool) -> Bool {
        guard index > 0 else { return true }
        if separators.contains(lowered[index - 1]) { return true }
        guard shapesMatch else { return false }
        return raw[index - 1].isLowercase && raw[index].isUppercase
    }
}
