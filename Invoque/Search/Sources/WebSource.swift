import Foundation

/// Always offers one fallback row: searching the web for the query. It sorts
/// below every real match (`SearchModel` pins `web:` ids last) so it never
/// steals Return from an app or a calculator result.
final class WebSource: ItemSource {

    // MARK: ItemSource

    /// One "Search the web" item for any non-blank query, none for blank.
    func items(matching query: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = Self.encode(trimmed),
              let url = URL(string: "https://duckduckgo.com/?q=" + encoded) else {
            return []
        }
        return [Item(
            id: Item.webIDPrefix + trimmed,
            title: "Search the web for \"\(trimmed)\"",
            subtitle: "Search DuckDuckGo in your browser",
            icon: .symbol("magnifyingglass"),
            action: .openURL(url),
            matchText: "web search \(trimmed)"
        )]
    }

    // MARK: Encoding

    /// Percent-encodes for a single `q=` value. `urlQueryAllowed` is wrong
    /// here: it leaves `&`, `+`, `=`, and `?` intact, which would split or
    /// corrupt the parameter. Only RFC 3986 unreserved characters pass
    /// through — `CharacterSet.alphanumerics` would wrongly let non-ASCII
    /// letters through unencoded — so the resulting `URL(string:)` cannot
    /// fail on encoding grounds.
    private static func encode(_ query: String) -> String? {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        return query.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
