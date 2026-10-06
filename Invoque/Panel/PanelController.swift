import AppKit
import OSLog
import SwiftUI

/// Owns the launcher panel: lazy creation, Spotlight-style positioning on the
/// screen under the mouse, show/hide/toggle, and dismissal when the panel is
/// cancelled or loses key status.
/// `Sendable` is asserted: the controller and its panel are main-queue
/// confined — every entry point is a main-affine caller (hotkey, menu,
/// model callbacks). The annotation exists so a reference can ride a
/// `@Sendable` hop *back* to main, not to license off-main use.
final class PanelController: NSObject, @unchecked Sendable {

    /// The panel's fixed content size. PLAN.md §3: fixed, not resizable — the
    /// card fills the window and the results list scrolls instead.
    private enum Size {
        static let width: CGFloat = 680
        static let height: CGFloat = 440
    }

    private static let logger = Logger(subsystem: "ch.lkmc.Invoque", category: "PanelPresentation")
    private static let visibilityCheckDelay: TimeInterval = 0.2

    private enum VisibilityCheckStage {
        case initial, reordered, replaced
    }

    private let preferences: Preferences
    private let searchModel: SearchModel
    private let model: PanelModel
    private let commandStore: CommandStore
    private let commandRunner: CommandRunner
    private let permissionGrants: CommandPermissionGrants
    private let isWindowOnscreen: (Int) -> Bool?
    private let scheduleVisibilityCheck: (DispatchWorkItem) -> Void
    /// Sequencing for overlapping command runs — only the newest delivers.
    private var commandRunGeneration = 0
    /// Bumped on every `hide()` — distinguishes "still the same summon"
    /// from "dismissed and re-summoned" when deciding whether an in-flight
    /// command run may still deliver `.items` rows.
    private var panelSession = 0
    private var panel: LauncherPanel?
    private var resignKeyObserver: NSObjectProtocol?
    /// Presentation intent must survive a native window refusing to order in.
    private var isPresented = false
    private var presentationGeneration = 0
    private var visibilityCheckWorkItem: DispatchWorkItem?
    /// Hosts the results window a pending file scan detaches into.
    private lazy var detachedSearchWindow = DetachedSearchWindowController(
        preferences: preferences)

    /// `model` is injected because the app's `AppSource.onReload` hook must
    /// reference it before `SearchModel` (which owns the source) exists.
    init(preferences: Preferences, model: PanelModel, searchModel: SearchModel,
         commandStore: CommandStore, commandRunner: CommandRunner,
         permissionGrants: CommandPermissionGrants,
         isWindowOnscreen: @escaping (Int) -> Bool? = WindowServerVisibility.isOnscreen,
         scheduleVisibilityCheck: @escaping (DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + PanelController.visibilityCheckDelay,
                                          execute: $0)
         }) {
        self.preferences = preferences
        self.searchModel = searchModel
        self.model = model
        self.commandStore = commandStore
        self.commandRunner = commandRunner
        self.permissionGrants = permissionGrants
        self.isWindowOnscreen = isWindowOnscreen
        self.scheduleVisibilityCheck = scheduleVisibilityCheck
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
            // A submitted query is a recallable one — a real pick, not a
            // dismiss, not a keystroke.
            self.model.recordSubmittedQuery()
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
        // ⏎ while a file scan streams: hide the launcher and hand the
        // session to its own window, where the walk keeps going and the
        // results stay actionable.
        model.onDetachFileSearch = { [weak self] session in
            guard let self else { return }
            self.hide()
            self.detachedSearchWindow.show(session: session,
                                           entryRules: self.model.entryRules,
                                           iconResolver: self.model.iconResolver)
        }
        // A pin/block made in the panel or Settings must also reshape a
        // detached results window's list — the shared hook is single-
        // subscriber, so the panel fans it out.
        model.onEntryRulesChanged = { [weak self] in
            self?.detachedSearchWindow.entryRulesDidChange()
        }
        model.searchModel = searchModel
        model.commandStore = commandStore
    }

    deinit {
        visibilityCheckWorkItem?.cancel()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    // MARK: Show / hide

    func toggle() {
        if isPresented {
            hide()
        } else {
            show()
        }
    }

    func show() {
        presentationGeneration &+= 1
        visibilityCheckWorkItem?.cancel()
        isPresented = true
        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.reset(clearQuery: !preferences.keepQueryOnReshow)

        // Window opacity is never animated. An ordered transparent NSPanel
        // can still own keyboard focus, and overlapping animator writes can
        // outlive the completion handlers that used to guard dismissal.
        // Establish the complete visible state before giving it the keyboard.
        if let screen = screenUnderMouse() {
            panel.setFrameOrigin(PanelGeometry.panelOrigin(
                inVisibleFrame: screen.visibleFrame, panelSize: panel.frame.size))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        focusResponder(in: panel)
        scheduleVisibilityVerification(of: panel, stage: .initial)
    }

    private func focusResponder(in panel: LauncherPanel, requestedResponder: NSView? = nil,
                                selection: NSRange? = nil) {
        // Key without activating the app. Fresh summons focus the header;
        // native repair restores the input the user was already editing.
        panel.makeKey()
        let target = requestedResponder ?? panel.preferredFirstResponder
        var restored = false
        if let target, panel.makeFirstResponder(target) {
            restored = restoreSelection(selection, in: target)
        }
        if !restored {
            // A first summon or a reparented control may still be attaching.
            // Retry after the hierarchy settles, only for this presentation.
            let generation = presentationGeneration
            let identifier = ObjectIdentifier(panel)
            DispatchQueue.main.async { [weak self, weak requestedResponder] in
                guard let self, self.isPresented,
                      self.presentationGeneration == generation,
                      let panel = self.panel, ObjectIdentifier(panel) == identifier,
                      panel.isVisible, panel.isKeyWindow,
                      let target = requestedResponder ?? panel.preferredFirstResponder,
                      target.window === panel else { return }
                if panel.makeFirstResponder(target) {
                    self.restoreSelection(selection, in: target)
                }
            }
        }
    }

    @discardableResult
    private func restoreSelection(_ selection: NSRange?, in target: NSView) -> Bool {
        guard let selection else { return true }
        guard let editor = (target as? NSTextView)
                ?? (target as? NSTextField)?.currentEditor() as? NSTextView else { return false }
        let length = (editor.string as NSString).length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location,
                                        length: min(selection.length, length - location)))
        return true
    }

    private func focusedContentView(in panel: LauncherPanel) -> (view: NSView?, selection: NSRange?) {
        guard let focusedView = panel.firstResponder as? NSView,
              let contentView = panel.contentView else { return (nil, nil) }
        let editor = focusedView as? NSTextView
        // A field editor belongs to the window rather than the content graph;
        // its delegate is the actual search, Maker or confirmation control.
        let target = editor?.isFieldEditor == true ? editor?.delegate as? NSView : focusedView
        guard let target, target === contentView || target.isDescendant(of: contentView) else {
            return (nil, nil)
        }
        return (target, editor?.selectedRange())
    }

    func hide() {
        isPresented = false
        presentationGeneration &+= 1
        visibilityCheckWorkItem?.cancel()
        visibilityCheckWorkItem = nil
        panelSession += 1
        // A dismissed panel must not keep working: a `find` walk would
        // scan the disk for minutes, and a `make` generation would keep
        // spending API budget for a result nobody sees. Cancel as soon as
        // the user dismisses the panel.
        model.panelDidHide()
        // Release the window immediately, including on key-resign. There
        // must be no invisible-but-key interval while a fade completes.
        panel?.orderOut(nil)
    }

    /// Spaces transitions can temporarily defer ordering. Retry once after the
    /// first offscreen sample, then replace only a persistently missing native
    /// window. Ordinary occlusion and an unavailable server query are not failures.
    private func scheduleVisibilityVerification(of panel: LauncherPanel, stage: VisibilityCheckStage) {
        let generation = presentationGeneration
        let identifier = ObjectIdentifier(panel)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented,
                  self.presentationGeneration == generation,
                  let panel = self.panel, ObjectIdentifier(panel) == identifier else { return }
            self.visibilityCheckWorkItem = nil
            guard self.isWindowOnscreen(panel.windowNumber) == false else { return }

            switch stage {
            case .initial:
                Self.logger.warning("Launcher window \(panel.windowNumber) remains offscreen; retrying ordering")
                panel.orderFrontRegardless()
                self.scheduleVisibilityVerification(of: panel, stage: .reordered)
            case .reordered:
                self.replaceUnorderedPanel(panel)
            case .replaced:
                Self.logger.error("Replacement launcher window \(panel.windowNumber) remains offscreen; no further repair in this presentation")
            }
        }
        visibilityCheckWorkItem = work
        scheduleVisibilityCheck(work)
    }

    private func replaceUnorderedPanel(_ oldPanel: LauncherPanel) {
        let oldWindowNumber = oldPanel.windowNumber
        let frame = oldPanel.frame
        let contentView = oldPanel.contentView
        let searchField = oldPanel.preferredFirstResponder
        let focus = focusedContentView(in: oldPanel)
        // Retiring a key panel sends resign-key. Remove its observer before
        // ordering out so replacement cannot dismiss or cancel the model session.
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        oldPanel.orderOut(nil)
        // Preserve the hosting graph, including Maker fields and other local
        // SwiftUI state. The confirmed failure is native ordering, not drawing.
        oldPanel.contentView = nil
        oldPanel.close()

        let replacement = makePanel(contentView: contentView)
        panel = replacement
        replacement.preferredFirstResponder = searchField
        replacement.setFrame(frame, display: true)
        replacement.alphaValue = 1
        replacement.orderFrontRegardless()
        focusResponder(in: replacement, requestedResponder: focus.view, selection: focus.selection)
        Self.logger.warning("Replaced offscreen launcher window \(oldWindowNumber) with \(replacement.windowNumber)")
        scheduleVisibilityVerification(of: replacement, stage: .replaced)
        // No second replacement in this presentation, even if the OS still refuses
        // it. A later user summon starts a new bounded verification sequence.
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
                    if self.isPresented,
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

    private func makePanel(contentView: NSView? = nil) -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Size.width, height: Size.height))
        panel.contentView = contentView ?? NSHostingView(rootView: PanelView(model: model,
                                                                           preferences: preferences))

        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.permissionRequest != nil {
                self.model.dismissPermissionRequest()
                return
            }
            if self.model.systemActionConfirmation != nil {
                self.model.dismissSystemActionConfirmation()
                return
            }
            self.hide()
        }

        // ⌘P pins, ⌘B blocks the selected entry. The model returns nil
        // when the chord doesn't apply (no manageable row selected, a
        // consent/maker card up) — show brief feedback so the user knows
        // why nothing happened.
        panel.onPinChord = { [weak self] in
            guard let self else { return }
            if let toast = self.model.togglePin() {
                HUD.show(toast, typeface: self.preferences.panelTypeface)
            } else if self.model.selectedRow != nil {
                HUD.show("Can't pin this row", typeface: self.preferences.panelTypeface)
            }
        }
        panel.onBlockChord = { [weak self] in
            guard let self else { return }
            if let toast = self.model.toggleBlock() {
                HUD.show(toast, typeface: self.preferences.panelTypeface)
            } else if self.model.selectedRow != nil {
                HUD.show("Can't block this row", typeface: self.preferences.panelTypeface)
            }
        }

        // ⌘C copies the selected row's target — the path, the URL, the
        // answer, or the title — and confirms with a toast.
        panel.onCopyChord = { [weak self] in
            guard let self, let payload = self.model.copySelectedRowPayload() else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            HUD.show("Copied \(payload)", typeface: self.preferences.panelTypeface)
        }

        // Hide on losing key status (click elsewhere, another window summoned).
        // Observed here rather than overridden on the window: the controller
        // owns dismissal (see LauncherPanel's class comment).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let self, let observed = notification.object as? LauncherPanel,
                  self.panel === observed else { return }
            self.hide()
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
