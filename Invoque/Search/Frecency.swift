import Foundation

/// Usage-based ranking boost: items you pick often and recently outrank
/// equally-matching ones. Counts plus last-used timestamps persist in
/// `UserDefaults` as one small Codable dictionary, so there is no database
/// to migrate.
///
/// Score curve: `min(visits, 20)` times a recency multiplier that is 1.0 for
/// an item used today and falls linearly to 0.2 at 30 days, then stays at
/// 0.2. Long-unused favorites keep a whisper of an advantage, never a veto,
/// and the 20-point ceiling means frecency breaks ties without beating a
/// clearly better text match on its own.
///
/// Not thread-safe: record and score from one thread (the panel's).
final class Frecency {

    // MARK: Types

    /// Per-item usage record. `lastUsed` is a Unix timestamp so the payload
    /// stays a plain JSON dictionary of small values.
    private struct Entry: Codable {
        var visits: Int
        var lastUsed: TimeInterval
    }

    // MARK: Configuration

    /// Storage key in `UserDefaults`. Version it if the schema changes.
    private static let storageKey = "SearchFrecency.v1"

    /// Upper bound on tracked ids; beyond this the least-recently-used ids
    /// are evicted. Keeps the plist small.
    private static let maxEntries = 500

    /// Visits above this stop adding boost, so a daily driver cannot
    /// permanently outrank everything else.
    private static let maxCountedVisits = 20

    /// Days over which the recency multiplier decays from 1.0 to its floor.
    private static let decayDays = 30.0

    /// Floor of the recency multiplier: stale favorites keep a small edge.
    private static let decayFloor = 0.2

    /// Seconds per day, for timestamp math.
    private static let secondsPerDay = 86_400.0

    // MARK: State

    private let defaults: UserDefaults
    private var entries: [String: Entry]

    // MARK: Init

    /// - Parameter defaults: Injected for tests; defaults to `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
    }

    // MARK: Recording

    /// Records a selection. Persists immediately; picks are rare (one per
    /// Return) so a write per pick is cheaper than a timer.
    func record(_ itemID: String) {
        var entry = entries[itemID] ?? Entry(visits: 0, lastUsed: 0)
        entry.visits += 1
        entry.lastUsed = Date().timeIntervalSince1970
        entries[itemID] = entry
        evictIfNeeded()
        save()
    }

    // MARK: Scoring

    /// Bounded boost for `itemID`, or 0 for never-recorded ids.
    func score(_ itemID: String) -> Double {
        guard let entry = entries[itemID] else { return 0 }
        let daysSinceUse = max(0, (Date().timeIntervalSince1970 - entry.lastUsed) / Self.secondsPerDay)
        let decay = max(
            Self.decayFloor,
            1 - (1 - Self.decayFloor) * min(daysSinceUse, Self.decayDays) / Self.decayDays
        )
        return Double(min(entry.visits, Self.maxCountedVisits)) * decay
    }

    // MARK: Persistence

    private static func load(from defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Evicts least-recently-used ids beyond the cap. Ties (identical
    /// timestamps from rapid successive records) break by id so eviction is
    /// deterministic.
    private func evictIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let victims = entries
            .sorted {
                if $0.value.lastUsed != $1.value.lastUsed {
                    return $0.value.lastUsed < $1.value.lastUsed
                }
                return $0.key < $1.key
            }
            .prefix(entries.count - Self.maxEntries)
            .map { $0.key }
        for victim in victims {
            entries.removeValue(forKey: victim)
        }
    }
}
