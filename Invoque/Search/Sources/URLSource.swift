import Foundation

/// When the query *is* an http(s) URL — typed or pasted — the top row opens
/// that URL, it doesn't search for it. `WebSource`'s fallback row would
/// otherwise own ⏎, sending "https://example.com/release" to a search
/// engine instead of the page.
///
/// `url:` ids pin alongside `path:` rows (PLAN §3): a typed address is a
/// direct intent, not a candidate among fuzzy matches. frecency ignores
/// the id — query-derived, like `web:`/`calc:`.
final class URLSource: ItemSource {

    // MARK: ItemSource

    /// One row for a well-formed http(s) URL; nothing otherwise — a query
    /// that merely contains a URL is a search, not an address.
    func items(matching query: String) -> [Item] {
        guard let url = Self.resolve(query) else { return [] }
        return [Item(
            id: Item.urlIDPrefix + url.absoluteString,
            title: url.absoluteString,
            subtitle: "Open the URL in your browser",
            icon: .symbol("globe"),
            action: .openURL(url),
            matchText: url.absoluteString
        )]
    }

    // MARK: Resolution

    /// The query as a web URL, or nil when it isn't one: a strict
    /// `URL(string:)` parse with an `http`/`https` scheme, a non-empty
    /// host, and no raw whitespace — Foundation's macOS 14+ parser
    /// percent-encodes invalid characters by default, so strict parsing
    /// is opted into there; a pasted address never carries a raw space
    /// (browsers percent-encode), so whitespace means the query is prose
    /// around an address. Other schemes (`mailto:`, `file:` — `PathSource`
    /// owns that one) are not URLs here. Mirrors the `invoque.open`
    /// module's http(s) allowlist.
    static func resolve(_ query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \Character.isWhitespace) else {
            return nil
        }
        // `URL(string:)` percent-encodes invalid characters on macOS 14+,
        // so opt into strict parsing there; older systems are already
        // strict — though the legacy parser still admits a few RFC-illegal
        // characters (e.g. `|`), so such pastes resolve as URLs only there.
        let parsed: URL?
        if #available(macOS 14.0, *) {
            parsed = URL(string: trimmed, encodingInvalidCharacters: false)
        } else {
            parsed = URL(string: trimmed)
        }
        guard let url = parsed,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}
