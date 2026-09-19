import XCTest
@testable import Invoque

final class SearchEngineTests: XCTestCase {

    /// Every engine builds a valid https URL carrying the encoded query —
    /// a typo'd template would drop the row silently at search time.
    func testEveryEngineBuildsAQueryURL() {
        XCTAssertFalse(SearchEngine.allCases.isEmpty,
                       "allCases empty — the loop body never executes")
        // Pin the advertised set (README lists nine engines) by rawValue —
        // a rename or swap keeps the count but resets every user's
        // persisted choice to the default.
        XCTAssertEqual(Set(SearchEngine.allCases.map(\.rawValue)),
                       ["duckDuckGo", "google", "bing", "kagi", "brave",
                        "startpage", "qwant", "ecosia", "mojeek"],
                       "engine set changed — update this pin and the README")
        // Reserved characters must survive verbatim — a template that
        // re-encodes or truncates at `?`/`#` would corrupt the query.
        for encodedQuery in ["hello%20world", "a%26b", "50%25%20off%3F", "q%23frag"] {
            for engine in SearchEngine.allCases {
                let url = engine.url(encodedQuery: encodedQuery)
                XCTAssertNotNil(url, "\(engine.rawValue) — \(encodedQuery)")
                XCTAssertEqual(url?.scheme, "https",
                               "\(engine.rawValue) — \(encodedQuery)")
                XCTAssertTrue(url?.absoluteString.contains(encodedQuery) ?? false,
                              "\(engine.rawValue) — \(encodedQuery)")
            }
        }
    }

    /// The fallback row routes through the configured engine — host and
    /// subtitle both name it.
    func testWebSourceHonorsTheEngine() throws {
        let source = WebSource(engine: { .kagi })
        let item = try XCTUnwrap(source.items(matching: "query").first)
        guard case .openURL(let url) = item.action else {
            return XCTFail("expected .openURL, got \(item.action)")
        }
        XCTAssertEqual(url.host, "kagi.com")
        XCTAssertTrue(item.subtitle.contains("Kagi"))
    }

    /// The default engine is DuckDuckGo — the pre-picker behavior. (The
    /// parameterless init's default is a literal, not UserDefaults.)
    func testDuckDuckGoIsTheDefault() throws {
        let item = try XCTUnwrap(WebSource().items(matching: "query").first)
        guard case .openURL(let url) = item.action else {
            return XCTFail("expected .openURL, got \(item.action)")
        }
        XCTAssertEqual(url.host, "duckduckgo.com")
    }

    /// Preferences round-trips the picker's choice and falls back to the
    /// default for a stored value that isn't a known engine.
    func testSearchEnginePreference() {
        let suite = "invoque-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.searchEngine, .duckDuckGo)

        preferences.searchEngine = .mojeek
        XCTAssertEqual(Preferences(defaults: defaults).searchEngine, .mojeek)
        // Pins the persisted key — a rename fails here, not silently below.
        XCTAssertEqual(defaults.string(forKey: "searchEngine"), "mojeek")

        defaults.set("altavista", forKey: "searchEngine")
        XCTAssertEqual(Preferences(defaults: defaults).searchEngine, .duckDuckGo)
    }
}
