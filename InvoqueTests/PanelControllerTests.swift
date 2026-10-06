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
    func testPanelCanJoinOtherApplicationsFullscreenSpaces() throws {
        try withController { _, panel in
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        }
    }

    @MainActor
    func testPersistentServerOrderingFailureReplacesPanelWithoutResettingSession() throws {
        let checks = VisibilityChecks()
        try withController(checks: checks) { controller, panel, model, grants in
            model.query = "notes"
            model.showCommandResults([
                ResultRow(id: "one", title: "One", subtitle: "", icon: .symbol("star"),
                          action: .copyText("one")),
                ResultRow(id: "two", title: "Two", subtitle: "", icon: .symbol("star"),
                          action: .copyText("two"))
            ])
            model.selection = 1
            let manifest = try JSONDecoder().decode(CommandManifest.self, from: Data("""
                {"schemaVersion":1,"name":"risky","title":"Risky","runtime":"js",
                 "entry":"main.js","mode":"action","permissions":["shell"]}
                """.utf8))
            let command = try Command(manifest: manifest,
                                      directory: URL(fileURLWithPath: "/tmp/invoque-risky"))
            let request = try XCTUnwrap(grants.consentRequest(for: command, args: ["arg"]))
            model.permissionRequest = request
            let rows = model.results
            let frame = panel.frame
            let contentView = panel.contentView
            let searchField = panel.preferredFirstResponder

            try checks.runNext()
            XCTAssertTrue(currentPanel() === panel, "First failure should only retry ordering")
            try checks.runNext()
            let replacement = try XCTUnwrap(currentPanel())
            XCTAssertFalse(replacement === panel)
            XCTAssertTrue(replacement.contentView === contentView,
                          "Native repair must retain the SwiftUI graph and unsent Maker inputs")
            XCTAssertTrue(replacement.preferredFirstResponder === searchField)
            if let searchField {
                XCTAssertTrue(searchField.window === replacement)
            }
            XCTAssertEqual(replacement.frame, frame)
            XCTAssertEqual(replacement.alphaValue, 1)
            XCTAssertTrue(replacement.isVisible)
            XCTAssertEqual(model.query, "notes")
            XCTAssertEqual(model.results, rows)
            XCTAssertEqual(model.selection, 1)
            XCTAssertEqual(model.permissionRequest?.grantKey, request.grantKey)
            try checks.runNext()
            XCTAssertTrue(currentPanel() === replacement)
            XCTAssertTrue(checks.workItems.isEmpty, "Recovery must be bounded to one replacement")

            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification,
                                            object: panel)
            XCTAssertTrue(replacement.isVisible, "Retired panel notifications must not hide its replacement")
            controller.hide()
            XCTAssertFalse(replacement.isVisible)
        }
    }

    @MainActor
    func testRecoveryKeepsPendingFileSearchAlive() throws {
        let originalDebounce = PanelModel.fileSearchDebounceNanoseconds
        PanelModel.fileSearchDebounceNanoseconds = 60_000_000_000
        defer { PanelModel.fileSearchDebounceNanoseconds = originalDebounce }
        let checks = VisibilityChecks()
        try withController(checks: checks) { controller, _, model, _ in
            model.fileSearcher = { _, _, _ in }
            model.query = "find notes"
            XCTAssertTrue(model.fileScanIsPending)
            try checks.runNext()
            try checks.runNext()
            XCTAssertEqual(model.query, "find notes")
            XCTAssertTrue(model.fileScanIsPending)
            XCTAssertEqual(model.fileRunCompletions, 0, "Recovery must not cancel the pending session")
            controller.hide()
            XCTAssertFalse(model.fileScanIsPending)
            XCTAssertEqual(model.fileRunCompletions, 1)
        }
    }

    @MainActor
    func testRecoveryRestoresTheActiveDraftFieldAndItsSelection() throws {
        let checks = VisibilityChecks()
        try withController(checks: checks) { _, panel, _, _ in
            let host = try XCTUnwrap(panel.contentView)
            // Native input belongs beside a hosting view, not inside the
            // hosting view's privately managed SwiftUI hierarchy.
            let contentView = NSView(frame: host.frame)
            panel.contentView = contentView
            contentView.addSubview(host)
            let draftField = NSTextField(frame: NSRect(x: 40, y: 40, width: 200, height: 24))
            draftField.stringValue = "Unsubmitted feedback"
            contentView.addSubview(draftField)
            XCTAssertTrue(panel.makeFirstResponder(draftField))
            let editor = try XCTUnwrap(draftField.currentEditor() as? NSTextView)
            let selection = NSRange(location: 2, length: 4)
            editor.setSelectedRange(selection)

            try checks.runNext()
            try checks.runNext()

            let replacement = try XCTUnwrap(currentPanel())
            XCTAssertFalse(replacement === panel)
            XCTAssertTrue(draftField.window === replacement)
            let restoredEditor = try XCTUnwrap(draftField.currentEditor() as? NSTextView,
                                              "Recovery must focus the active draft field, not the header")
            XCTAssertTrue(replacement.firstResponder === restoredEditor)
            XCTAssertTrue((restoredEditor.delegate as? NSTextField) === draftField)
            XCTAssertEqual(restoredEditor.selectedRange(), selection)
            XCTAssertEqual(draftField.stringValue, "Unsubmitted feedback")
        }
    }

    @MainActor
    func testDismissalCancelsQueuedRecovery() throws {
        let checks = VisibilityChecks()
        try withController(checks: checks) { controller, panel, _, _ in
            try checks.runNext()
            controller.hide()
            try checks.runNext()
            XCTAssertTrue(currentPanel() === panel)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(checks.probedWindows.count, 1)
        }
    }

    @MainActor
    func testNewSummonInvalidatesPreviousRecovery() throws {
        let checks = VisibilityChecks()
        try withController(checks: checks) { controller, panel, _, _ in
            try checks.runNext()
            controller.hide()
            controller.show()
            checks.verdict = true
            try checks.runNext()
            try checks.runNext()
            XCTAssertTrue(currentPanel() === panel)
            XCTAssertEqual(checks.probedWindows.count, 2)
            XCTAssertTrue(checks.workItems.isEmpty)
        }
    }

    @MainActor
    func testRecoveredOrderingDoesNotRecreatePanel() throws {
        let checks = VisibilityChecks()
        try withController(checks: checks) { _, panel, _, _ in
            try checks.runNext()
            checks.verdict = true
            try checks.runNext()
            XCTAssertTrue(currentPanel() === panel)
            XCTAssertTrue(checks.workItems.isEmpty)
        }
    }

    @MainActor
    func testHealthyAndUnknownServerStateKeepExistingPanel() throws {
        for verdict: Bool? in [true, nil] {
            let checks = VisibilityChecks()
            checks.verdict = verdict
            try withController(checks: checks) { _, panel, _, _ in
                try checks.runNext()
                XCTAssertTrue(currentPanel() === panel)
                XCTAssertTrue(checks.workItems.isEmpty)
            }
        }
    }

    private final class VisibilityChecks {
        var verdict: Bool? = false
        var workItems: [DispatchWorkItem] = []
        var probedWindows: [Int] = []

        func runNext() throws {
            let work = try XCTUnwrap(workItems.first, "Presentation verification must be scheduled")
            workItems.removeFirst()
            work.perform()
        }
    }

    @MainActor
    private func currentPanel() -> LauncherPanel? {
        NSApp.windows.compactMap { $0 as? LauncherPanel }.first { $0.isVisible }
            ?? NSApp.windows.compactMap { $0 as? LauncherPanel }.last
    }

    @MainActor
    private func withController(
        _ check: (PanelController, LauncherPanel) throws -> Void
    ) throws {
        try withController(checks: VisibilityChecks()) { controller, panel, _, _ in
            try check(controller, panel)
        }
    }

    @MainActor
    private func withController(
        checks: VisibilityChecks,
        _ check: (PanelController, LauncherPanel, PanelModel, CommandPermissionGrants) throws -> Void
    ) throws {
        let suite = "invoque-panel-controller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let model = PanelModel()
        let search = SearchModel(sources: [], frecency: Frecency(defaults: defaults))
        let grants = CommandPermissionGrants(defaults: defaults)
        let controller = PanelController(
            preferences: preferences, model: model, searchModel: search,
            commandStore: CommandStore(rootPaths: []), commandRunner: CommandRunner(),
            permissionGrants: grants,
            isWindowOnscreen: { checks.probedWindows.append($0); return checks.verdict },
            scheduleVisibilityCheck: { checks.workItems.append($0) })
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? LauncherPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        defer {
            controller.hide()
            for window in NSApp.windows.compactMap({ $0 as? LauncherPanel })
                where !existing.contains(ObjectIdentifier(window)) {
                window.close()
            }
        }
        try check(controller, panel, model, grants)
    }
}
