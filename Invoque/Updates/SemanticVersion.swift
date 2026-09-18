import Foundation

/// A lightweight semantic-version value for comparing an app's version against a
/// release tag. Parses the leading `major[.minor[.patch[.…]]]` number from strings
/// like `"1.2.3"`, `"v1.2.3"`, or `"1.4.0-beta.2"`, ignoring any build-metadata
/// suffix and treating a pre-release as sorting *below* its final release
/// (`1.2.0-beta < 1.2.0`).
///
/// Reusable across apps — depends only on Foundation.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {

    /// The dot-separated numeric components (e.g. `[1, 2, 3]`).
    let components: [Int]
    /// The pre-release identifier (the part after `-`), or `nil` for a final release.
    let prerelease: String?
    /// The original (trimmed) string, kept for display.
    let original: String

    static let zero = SemanticVersion("0")!

    /// Parses `raw`, returning `nil` if it has no leading numeric version.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var s = trimmed
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        // Drop build metadata (`+…`), then split off a pre-release (`-…`).
        s = s.split(separator: "+", maxSplits: 1).first.map(String.init) ?? s
        let dashSplit = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberPart = dashSplit.first.map(String.init) ?? s
        let pre = dashSplit.count > 1 ? String(dashSplit[1]) : nil

        let parsed = numberPart.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }

        self.components = parsed.compactMap { $0 }
        self.prerelease = (pre?.isEmpty == false) ? pre : nil
        self.original = trimmed
    }

    var description: String { original }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // Compare numeric components, padding the shorter with zeros (1.2 == 1.2.0).
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        // Equal numbers: a pre-release is older than the final release.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?):  return false   // final > pre-release
        case (_?, nil):  return true    // pre-release < final
        case let (l?, r?):
            // Both pre-release: compare dot-separated identifiers per semver
            // §11 — numeric fields numerically ("beta.10" > "beta.2"), and a
            // numeric identifier always ranks below an alphanumeric one. A
            // lexical fallback for mixed pairs would be non-transitive
            // ("beta.2" < "beta.10" < "beta.1a" < "beta.2" — a cycle).
            func isNumeric(_ s: Substring) -> Bool {
                s.allSatisfy { $0.isASCII && $0.isNumber }
            }
            return l.split(separator: ".").lexicographicallyPrecedes(
                r.split(separator: ".")) { a, b in
                    if isNumeric(a) && isNumeric(b) {
                        if let x = Int(a), let y = Int(b) { return x < y }
                        // Digit strings too long for Int: compare magnitudes —
                        // trim leading zeros first (a long "0…09" parses as a
                        // small Int yet out-lengths an overflowing peer, which
                        // would invert the order and re-open the cycle).
                        let lt = a.drop(while: { $0 == "0" })
                        let rt = b.drop(while: { $0 == "0" })
                        if lt.count != rt.count { return lt.count < rt.count }
                        return lt < rt
                    }
                    switch (isNumeric(a), isNumeric(b)) {
                    case (true, false): return true    // numeric < alphanumeric
                    case (false, true): return false
                    default: return a < b
                    }
                }
        }
    }

    /// Semantic equality (so `1.2` equals `1.2.0`), independent of the raw string.
    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
