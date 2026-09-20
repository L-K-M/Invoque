import AppKit
import SwiftUI

/// Owns the launcher panel: lazy creation, Spotlight-style positioning on the
/// screen under the mouse, show/hide/toggle, and dismissal when the panel is
/// cancelled or loses key status.
final class PanelController: NSObject {

    /// The panel's fixed content size. PLAN.md §3: fixed, not resizable — the
    /// card fills the window and the results list scrolls instead.
    private enum Size {
        static let width: CGFloat = 680
        static let height: CGFloat = 440
    }

    private let preferences: Preferences
    private let searchModel: SearchModel
    private let model: PanelModel
    private let commandStore: CommandStore
    private let commandRunner: CommandRunner
    private let permissionGrants: CommandPermissionGrants
    /// Sequencing for overlapping command runs — only the newest delivers.
    private var commandRunGeneration = 0
    /// Bumped on every `hide()` — distinguishes "still the same summon"
    /// from "dismissed and re-summoned" when deciding whether an in-flight
    /// command run may still deliver `.items` rows.
    private var panelSession = 0
    private var panel: LauncherPanel?
    private var resignKeyObserver: NSObjectProtocol?

    /// `model` is injected because the app's `AppSource.onReload` hook must
    /// reference it before `SearchModel` (which owns the source) exists.
    init(preferences: Preferences, model: PanelModel, searchModel: SearchModel,
         commandStore: CommandStore, commandRunner: CommandRunner,
         permissionGrants: CommandPermissionGrants) {
        self.preferences = preferences
        self.searchModel = searchModel
        self.model = model
        self.commandStore = commandStore
        self.commandRunner = commandRunner
        self.permissionGrants = permissionGrants
        super.init()

        // Dismiss first, then perform: a slow action (app launch, AppleEvent
        // consent) must not hold the panel open. `.runCommand` is the
        // exception — an async command run isn't blocking, and a `{items}`
        // result needs the list to stay.
        model.onSubmit = { [weak self] row in
            guard let self else { return }
            guard let row else {
                self.hide()
                return
            }
            self.searchModel.recordSelection(itemID: row.id)
            if case .runCommand(let name, let args) = row.action {
                self.runCommand(named: name, args: args)
                return
            }
            self.hide()
            ActionPerformer.perform(row.action)
        }
        // Consent granted → record the grant here, where the ungranted
        // check runs, then resume the paused run — a single owner for the
        // write and the read, so Allow can never re-prompt forever.
        model.onPermissionConfirmed = { [weak self] request in
            self?.permissionGrants.grant(request)
            self?.runCommand(named: request.command.name, args: request.args)
        }
        model.searchModel = searchModel
    }

    deinit {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    // MARK: Show / hide

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.reset(clearQuery: !preferences.keepQueryOnReshow)

        if let screen = screenUnderMouse() {
            let size = NSSize(width: Size.width, height: Size.height)
            panel.setFrameOrigin(
                PanelGeometry.panelOrigin(inVisibleFrame: screen.visibleFrame, panelSize: size))
        }

        panel.orderFrontRegardless()
        // Key without activating the app (`.nonactivatingPanel`), then hand
        // focus to the search field for immediate typing.
        panel.makeKey()
        if let field = panel.preferredFirstResponder {
            panel.makeFirstResponder(field)
        } else {
            // On the very first summon the SwiftUI hierarchy may not have
            // attached yet, so `preferredFirstResponder` is still nil.
            // SearchTextField.viewDidMoveToWindow covers this too, but a
            // next-runloop retry keeps focus deterministic either way.
            DispatchQueue.main.async { [weak panel] in
                if let field = panel?.preferredFirstResponder {
                    panel?.makeFirstResponder(field)
                }
            }
        }
    }

    func hide() {
        panelSession += 1
        panel?.orderOut(nil)
    }

    // MARK: Commands

    /// Runs an action-mode command. The panel stays up while it runs —
    /// the run is async, so nothing blocks — then:
    /// `{items}` replaces the list in place (PLAN §4.1), `{title}` shows
    /// the HUD and dismisses, `.void` dismisses silently, and a failure
    /// surfaces as a one-line HUD so it isn't invisible.
    private func runCommand(named name: String, args: [String]) {
        guard let command = commandStore.command(named: name) else {
            hide()
            HUD.show("Unknown command: \(name)", typeface: preferences.panelTypeface)
            return
        }
        // First-run consent (PLAN §4.3): a command declaring risky
        // permissions pauses here and the panel shows the confirmation
        // card — nothing executes until the user allows.
        if let request = permissionGrants.consentRequest(for: command, args: args) {
            model.permissionRequest = request
            return
        }
        // Only the newest run may deliver — a slow earlier command must not
        // overwrite a newer run's results (or fire a second stale HUD).
        commandRunGeneration += 1
        let generation = commandRunGeneration
        let submittedQuery = model.query
        let submittedPanelSession = panelSession
        let runner = commandRunner
        Task {
            let result = await runner.run(command: command, args: args)
            await MainActor.run { [weak self] in
                guard let self,
                      self.commandRunGeneration == generation else { return }
                // A failure surfaces as a one-line HUD regardless of the
                // output shape — today errors always carry .void, but a
                // future runner could pair partial output with an error.
                if let error = result.error {
                    self.hide()
                    HUD.show(error.localizedDescription, typeface: preferences.panelTypeface)
                    return
                }
                switch result.output {
                case .items(let items):
                    // Dropped when the panel was dismissed mid-run or the
                    // query moved on — stale rows must not greet the next
                    // summon or stomp fresh search results. The session
                    // check catches dismiss-then-resummon, where visibility
                    // and query can both match again.
                    if self.panel?.isVisible == true,
                       self.model.query == submittedQuery,
                       self.panelSession == submittedPanelSession {
                        self.model.showCommandResults(
                            PanelModel.commandRows(command: command, items: items))
                    }
                case .title(let title):
                    self.hide()
                    HUD.show(title, typeface: preferences.panelTypeface)
                case .void:
                    self.hide()
                }
            }
        }
    }

    // MARK: Panel lifecycle

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Size.width, height: Size.height))
        panel.contentView = NSHostingView(rootView: PanelView(model: model,
                                                              preferences: preferences))

        panel.onCancel = { [weak self] in self?.hide() }

        // ⌘P pins, ⌘B blocks the selected entry. The model returns nil
        // when the chord doesn't apply (no manageable row selected, a
        // consent/maker card up) — no toast for a no-op.
        panel.onPinChord = { [weak self] in
            guard let self, let toast = self.model.togglePin() else { return }
            HUD.show(toast, typeface: self.preferences.panelTypeface)
        }
        panel.onBlockChord = { [weak self] in
            guard let self, let toast = self.model.toggleBlock() else { return }
            HUD.show(toast, typeface: self.preferences.panelTypeface)
        }

        // Hide on losing key status (click elsewhere, another window summoned).
        // Observed here rather than overridden on the window: the controller
        // owns dismissal (see LauncherPanel's class comment).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }

        return panel
    }

    /// The display the cursor is on, so the panel summons where the user is
    /// looking. Falls back to the main screen.
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
