import AppKit
import XCTest
@testable import Invoque

final class PanelControllerTests: XCTestCase {

    @MainActor
    func testDismissalImmediatelyStopsPresentingThePanel() throws {
        try withController { controller, panel in
            controller.hide()
            XCTAssertFalse(panel.isVisible,
                           "A dismissed launcher must stop holding a visible window immediately")
        }
    }

    @MainActor
    func testRapidTogglesAlwaysRestoreAnOpaquePanel() throws {
        try withController { controller, panel in
            for _ in 0..<20 {
                controller.toggle()
                XCTAssertFalse(panel.isVisible)
                controller.toggle()
                XCTAssertTrue(panel.isVisible)
                XCTAssertEqual(panel.alphaValue, 1)
            }
        }
    }

    @MainActor
    func testShowRepairsTransparentWindowState() throws {
        try withController { controller, panel in
            panel.alphaValue = 0
            controller.show()
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.alphaValue, 1)
        }
    }

    @MainActor
    private func withController(
        _ check: (PanelController, LauncherPanel) throws -> Void
    ) throws {
        let suite = "invoque-panel-controller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let model = PanelModel()
        let search = SearchModel(sources: [], frecency: Frecency(defaults: defaults))
        let controller = PanelController(
            preferences: preferences, model: model, searchModel: search,
            commandStore: CommandStore(rootPaths: []), commandRunner: CommandRunner(),
            permissionGrants: CommandPermissionGrants(defaults: defaults))
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? LauncherPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        defer {
            controller.hide()
            panel.orderOut(nil)
        }
        try check(controller, panel)
    }
}
