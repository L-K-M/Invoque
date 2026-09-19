import Foundation

/// The engine the "Search the web" fallback row queries (Settings →
/// General → Search). A curated set: the mainstream defaults plus the
/// privacy engines and the independents — each just needs a `GET` query
/// endpoint, no API key.
enum SearchEngine: String, CaseIterable, Identifiable {

    case duckDuckGo
    case google
    case bing
    case kagi
    case brave
    case startpage
    case qwant
    case ecosia
    case mojeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        case .qwant: return "Qwant"
        case .ecosia: return "Ecosia"
        case .mojeek: return "Mojeek"
        }
    }

    /// The search URL for an already-percent-encoded query — encoding is
    /// `WebSource`'s job, the same rules for every engine.
    func url(encodedQuery: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/?q="
        case .google: base = "https://www.google.com/search?q="
        case .bing: base = "https://www.bing.com/search?q="
        case .kagi: base = "https://kagi.com/search?q="
        case .brave: base = "https://search.brave.com/search?q="
        case .startpage: base = "https://www.startpage.com/sp/search?query="
        case .qwant: base = "https://www.qwant.com/?q="
        case .ecosia: base = "https://www.ecosia.org/search?q="
        case .mojeek: base = "https://www.mojeek.com/search?q="
        }
        return URL(string: base + encodedQuery)
    }
}
