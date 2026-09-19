import XCTest
@testable import Invoque

final class SearchEngineTests: XCTestCase {

    /// Every engine builds a valid https URL carrying the encoded query —
    /// a typo'd template would drop the row silently at search time.
    func testEveryEngineBuildsAQueryURL() {
        for engine in SearchEngine.allCases {
            let url = engine.url(encodedQuery: "hello%20world")
            XCTAssertNotNil(url, engine.rawValue)
            XCTAssertEqual(url?.scheme, "https", engine.rawValue)
            XCTAssertTrue(url?.absoluteString.contains("hello%20world") ?? false,
                          engine.rawValue)
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

    /// The default engine is DuckDuckGo — the pre-picker behavior.
    func testDuckDuckGoIsTheDefault() {
        let item = WebSource().items(matching: "query").first
        guard case .openURL(let url)? = item?.action else {
            return XCTFail("expected .openURL")
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

        defaults.set("altavista", forKey: "searchEngine")
        XCTAssertEqual(Preferences(defaults: defaults).searchEngine, .duckDuckGo)
    }
}
