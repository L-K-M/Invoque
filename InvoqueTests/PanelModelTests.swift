import XCTest
@testable import Invoque

final class PanelModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "invoque-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeModel(items: [Item]) -> PanelModel {
        let model = PanelModel()
        model.searchModel = SearchModel(
            sources: [StubSource(stubbed: items)],
            frecency: Frecency(defaults: defaults))
        return model
    }

    private static func appItem(id: String, title: String) -> Item {
        Item(id: id, title: title, subtitle: "", icon: .symbol("app"),
             action: .openApp(URL(fileURLWithPath: "/Applications/\(title).app")),
             matchText: title)
    }

    // MARK: Query → results

    func testQueryChangePopulatesResults() {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.query = "safari"
        XCTAssertEqual(model.results.map(\.title), ["Safari"])
    }

    func testEmptyQueryYieldsNoResults() {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.query = "safari"
        XCTAssertFalse(model.results.isEmpty)
        model.query = ""
        XCTAssertTrue(model.results.isEmpty)
    }

    func testNewResultSetResetsSelectionToTop() {
        let model = makeModel(items: [
            Self.appItem(id: "app:one", title: "Alpha"),
            Self.appItem(id: "app:two", title: "Amber"),
        ])
        model.query = "a"
        // Same length, same match — the tie breaks by title: Alpha first.
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedRow?.id, "app:two")

        // A new query replaces the list — the index must not carry over
        // onto an unrelated row. "alph" still matches one app (Alpha), so
        // the reset is exercised against a non-empty result set.
        model.query = "alph"
        XCTAssertEqual(model.results.map(\.id), ["app:one"])
        XCTAssertEqual(model.selection, 0)
    }

    func testRefreshResultsRerunsOpenQuery() {
        let source = StubSource(stubbed: [Self.appItem(id: "app:safari", title: "Safari")])
        let model = PanelModel()
        model.searchModel = SearchModel(sources: [source],
                                        frecency: Frecency(defaults: defaults))
        model.query = "safari"
        source.stubbed = []
        // AppSource.onReload lands here: a scan finishing after the panel
        // opened must refill the visible list without a keystroke.
        model.refreshResults()
        XCTAssertTrue(model.results.isEmpty)
    }

    // MARK: Submit

    func testSubmitHandsSelectedRowToCallback() {
        let model = makeModel(items: [Self.appItem(id: "app:safari", title: "Safari")])
        model.query = "safari"
        var submitted: ResultRow?
        model.onSubmit = { submitted = $0 }
        model.submit()
        XCTAssertEqual(submitted?.id, "app:safari")
        guard case .openApp? = submitted?.action else {
            return XCTFail("expected openApp action, got \(String(describing: submitted?.action))")
        }
    }

    func testSubmitWithNoResultsPassesNil() {
        let model = makeModel(items: [])
        model.query = "nothing matches"
        var called = false
        model.onSubmit = { called = true; XCTAssertNil($0) }
        model.submit()
        XCTAssertTrue(called)
    }

    // MARK: Helpers

    private final class StubSource: ItemSource {
        var stubbed: [Item]
        init(stubbed: [Item]) { self.stubbed = stubbed }
        func items(matching query: String) -> [Item] { stubbed }
    }
}
