import Foundation

/// Instant-answer generators: `uuid`, `now`, `flip`, `roll`/`dN`. The query
/// must *be* the keyword — generators never fire on partials or fuzzy
/// input, so typing toward "Time Machine" doesn't trip `now`.
///
/// Values are fresh per query: each `items(matching:)` call rolls, stamps,
/// or mints anew, and the row freezes once the query settles (rows only
/// refresh on query or source changes). `gen:` ids are durable per
/// generator, so selection and equality behave; they are not frecency
/// candidates or manageable entries (not in `recordSelection`'s eligible
/// namespaces, not in `isManageableID`).
final class GeneratorSource: ItemSource {

    /// Mints a fresh UUID string (uppercase canonical form).
    private let makeUUID: () -> String
    /// The clock `now` reads.
    private let now: () -> Date
    /// Rolls 1...sides inclusive.
    private let roll: (Int) -> Int

    init(makeUUID: @escaping () -> String = { UUID().uuidString },
         now: @escaping () -> Date = { Date() },
         roll: @escaping (Int) -> Int = { sides in
             Int.random(in: 1...max(2, sides))
         }) {
        self.makeUUID = makeUUID
        self.now = now
        self.roll = roll
    }

    // MARK: ItemSource

    func items(matching query: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch trimmed {
        case "uuid", "guid":
            return [Self.uuidItem(makeUUID: makeUUID)]
        case "now":
            return [Self.nowItem(now: now)]
        case "flip", "flip coin":
            return [Self.flipItem(roll: roll)]
        default:
            if let sides = Self.parseDiceKeyword(trimmed) {
                return [Self.rollItem(sides: sides, roll: roll)]
            }
            return []
        }
    }

    // MARK: Keywords

    /// `roll` (default d20), `roll dN`, and a bare `dN` — Alfred/Raycast
    /// dice muscle memory. Sides below 2 decline: a one-sided die is a
    /// constant, not a roll.
    static func parseDiceKeyword(_ keyword: String) -> Int? {
        if keyword == "roll" { return 20 }
        var rest = Substring(keyword)
        if rest.hasPrefix("roll d") {
            rest = rest.dropFirst("roll d".count)
        } else if rest.hasPrefix("d") {
            rest = rest.dropFirst(1)
        } else {
            return nil
        }
        guard !rest.isEmpty,
              rest.allSatisfy({ $0.isASCII && $0.isNumber }),
              let sides = Int(rest), sides >= 2 else { return nil }
        return sides
    }

    // MARK: Items

    private static func uuidItem(makeUUID: () -> String) -> Item {
        let value = makeUUID()
        return Item(
            id: Item.generatorIDPrefix + "uuid",
            title: value,
            subtitle: "Fresh UUID v4 — ⏎ copies",
            icon: .symbol("doc.on.doc"),
            action: .copyText(value),
            matchText: "uuid guid generator")
    }

    private static func nowItem(now: () -> Date) -> Item {
        let stamp = Self.isoFormatter.string(from: now())
        return Item(
            id: Item.generatorIDPrefix + "now",
            title: stamp,
            subtitle: "UTC, ISO 8601 — ⏎ copies",
            icon: .symbol("clock"),
            action: .copyText(stamp),
            matchText: "now time timestamp date")
    }

    private static func flipItem(roll: (Int) -> Int) -> Item {
        // The coin is a d2 under the hood — one injected RNG for all rolls.
        let heads = roll(2) == 1
        let face = heads ? "Heads" : "Tails"
        return Item(
            id: Item.generatorIDPrefix + "flip",
            title: face,
            subtitle: "Flip a coin — ⏎ copies",
            icon: .symbol("circle.lefthalf.filled"),
            action: .copyText(face),
            matchText: "flip coin heads tails")
    }

    private static func rollItem(sides: Int, roll: (Int) -> Int) -> Item {
        let value = roll(sides)
        return Item(
            id: Item.generatorIDPrefix + "roll",
            title: "\(value)",
            subtitle: "Roll d\(sides) — ⏎ copies",
            icon: .symbol("dice"),
            action: .copyText("\(value)"),
            matchText: "roll dice d\(sides)")
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` — the copy-paste-safe stamp.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
