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
            XCTAssertTrue(panel.firstResponder === editor,
                          "The ordering retry must retain the active draft input")
            XCTAssertEqual(editor.selectedRange(), selection)
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
    func testReorderingRetriesFocusAfterInitialFocusWasLost() throws {
        let checks = VisibilityChecks()
        try withController(checks: checks) { _, panel, _, _ in
            let host = try XCTUnwrap(panel.contentView)
            let contentView = NSView(frame: host.frame)
            panel.contentView = contentView
            contentView.addSubview(host)
            let searchField = NSTextField(frame: NSRect(x: 40, y: 40, width: 200, height: 24))
            contentView.addSubview(searchField)
            panel.preferredFirstResponder = searchField
            XCTAssertTrue(panel.makeFirstResponder(nil))
            XCTAssertNil(searchField.currentEditor())

            try checks.runNext()

            XCTAssertTrue(currentPanel() === panel)
            // AppKit can defer key ownership in a background test host; the
            // deterministic invariant here is the restored content responder.
            let editor = try XCTUnwrap(searchField.currentEditor() as? NSTextView,
                                      "A successful reorder must retry the abandoned input focus")
            XCTAssertTrue(panel.firstResponder === editor)
            XCTAssertTrue((editor.delegate as? NSTextField) === searchField)
            checks.verdict = true
            try checks.runNext()
            XCTAssertTrue(currentPanel() === panel)
            XCTAssertTrue(panel.firstResponder === editor)
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
    func testCommandReturnRevealsSelectedAppFromFocusedSearchField() throws {
        for keyCode: UInt16 in [36, 76] { // Return and keypad Enter
            try withController(checks: VisibilityChecks()) { _, panel, model, _ in
                let appURL = URL(fileURLWithPath: "/Applications/claude-replicant.app")
                model.query = "claude-replicant"
                model.showCommandResults([
                    ResultRow(id: "app:claude-replicant", title: "claude-replicant",
                              subtitle: appURL.path, icon: .symbol("app"),
                              action: .openApp(appURL))
                ])
                var actions: [Item.Action] = []
                model.onSubmit = { row in
                    if let row { actions.append(row.action) }
                }
                panel.contentView?.layoutSubtreeIfNeeded()
                let field = try XCTUnwrap(panel.preferredFirstResponder as? NSTextField)
                XCTAssertTrue(panel.makeFirstResponder(field))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                XCTAssertTrue(panel.firstResponder === editor)
                let flags: NSEvent.ModifierFlags = keyCode == 76
                    ? [.command, .numericPad] : .command
                let event = try returnEvent(in: panel, modifiers: flags, keyCode: keyCode)

                XCTAssertTrue(panel.performKeyEquivalent(with: event))

                XCTAssertEqual(actions, [.revealInFinder(appURL)])
                XCTAssertEqual(model.query, "claude-replicant")
                XCTAssertEqual(field.stringValue, "claude-replicant")
                let repeatEvent = try returnEvent(in: panel, modifiers: flags,
                                                 keyCode: keyCode, isARepeat: true)
                XCTAssertTrue(panel.performKeyEquivalent(with: repeatEvent))
                XCTAssertEqual(actions.count, 1, "A held shortcut must submit only once")
            }
        }
    }

    @MainActor
    func testPlainReturnStillOpensSelectedAppViaFieldEditor() throws {
        try withController(checks: VisibilityChecks()) { _, panel, model, _ in
            let appURL = URL(fileURLWithPath: "/Applications/claude-replicant.app")
            model.showCommandResults([
                ResultRow(id: "app:claude-replicant", title: "claude-replicant",
                          subtitle: appURL.path, icon: .symbol("app"),
                          action: .openApp(appURL))
            ])
            var actions: [Item.Action] = []
            model.onSubmit = { row in
                if let row { actions.append(row.action) }
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(panel.preferredFirstResponder as? NSTextField)
            XCTAssertTrue(panel.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            let event = try returnEvent(in: panel)

            XCTAssertFalse(panel.performKeyEquivalent(with: event))
            XCTAssertTrue(actions.isEmpty)
            editor.interpretKeyEvents([event])

            XCTAssertEqual(actions, [.openApp(appURL)])
        }
    }

    @MainActor
    func testCommandReturnLeavesMarkedTextForTheInputMethod() throws {
        try withController(checks: VisibilityChecks()) { _, panel, model, _ in
            panel.contentView?.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(panel.preferredFirstResponder as? NSTextField)
            XCTAssertTrue(panel.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setMarkedText("claude", selectedRange: NSRange(location: 6, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            var submissions = 0
            model.onSubmit = { _ in submissions += 1 }
            let event = try returnEvent(in: panel, modifiers: .command)

            XCTAssertFalse(panel.performKeyEquivalent(with: event))

            XCTAssertEqual(submissions, 0)
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.string, "claude")
        }
    }

    @MainActor
    func testCommandReturnDoesNotSubmitWhileAnotherInputHasFocus() throws {
        try withController(checks: VisibilityChecks()) { _, panel, model, _ in
            let host = try XCTUnwrap(panel.contentView)
            let contentView = NSView(frame: host.frame)
            panel.contentView = contentView
            contentView.addSubview(host)
            let draftField = NSTextField(frame: NSRect(x: 40, y: 40, width: 200, height: 24))
            contentView.addSubview(draftField)
            XCTAssertTrue(panel.makeFirstResponder(draftField))
            var submissions = 0
            model.onSubmit = { _ in submissions += 1 }
            let event = try returnEvent(in: panel, modifiers: .command)

            XCTAssertFalse(panel.performKeyEquivalent(with: event))

            XCTAssertEqual(submissions, 0)
            XCTAssertTrue(panel.firstResponder === draftField.currentEditor())
        }
    }

    @MainActor
    func testHeldCommandReturnCannotConfirmSystemAction() throws {
        try withController(checks: VisibilityChecks()) { _, panel, model, _ in
            model.showCommandResults([
                ResultRow(id: "system:emptyTrash", title: "Empty Trash", subtitle: "",
                          icon: .symbol("trash"), action: .system(.emptyTrash))
            ])
            var actions: [Item.Action] = []
            model.onSubmit = { row in
                if let row { actions.append(row.action) }
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(panel.preferredFirstResponder as? NSTextField)
            XCTAssertTrue(panel.makeFirstResponder(field))
            let event = try returnEvent(in: panel, modifiers: .command)
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertEqual(model.systemActionConfirmation?.action, .emptyTrash)
            XCTAssertTrue(actions.isEmpty)

            let repeatEvent = try returnEvent(in: panel, modifiers: .command, isARepeat: true)
            XCTAssertTrue(panel.performKeyEquivalent(with: repeatEvent))
            XCTAssertTrue(actions.isEmpty)

            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertEqual(actions, [.system(.emptyTrash)])
        }
    }

    @MainActor
    private func returnEvent(in panel: LauncherPanel,
                             modifiers: NSEvent.ModifierFlags = [],
                             keyCode: UInt16 = 36,
                             isARepeat: Bool = false) throws -> NSEvent {
        let character = keyCode == 76 ? "\u{3}" : "\r"
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: isARepeat, keyCode: keyCode))
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
