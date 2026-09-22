import AppKit
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

    /// Animation constants — a short slide-in from above with fade.
    private enum Animation {
        static let duration: TimeInterval = 0.15
        static let slideOffset: CGFloat = 8
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
    /// Bumped on every show/hide. A hide animation's completion only
    /// orders the panel out while its generation is still current —
    /// a show() mid-fade turns the pending completion into a no-op.
    private var animationGeneration = 0
    /// True while a hide animation is fading the panel out — the panel
    /// still reports `isVisible` during the fade, so `toggle()` needs
    /// this to know a hotkey press should bring it back, not hide again.
    private var hideInFlight = false
    /// The panel's origin when the in-flight hide began. A mid-fade
    /// show() reverses toward this — `panel.frame` is only partway to
    /// the hide's offset target then (window frame animations
    /// interpolate the real frame), so it can't be derived in place.
    private var hideRestingOrigin: CGPoint?
    /// Hosts the results window a pending file scan detaches into.
    private lazy var detachedSearchWindow = DetachedSearchWindowController(
        preferences: preferences)

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
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    // MARK: Show / hide

    func toggle() {
        if panel?.isVisible == true, !hideInFlight {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.reset(clearQuery: !preferences.keepQueryOnReshow)

        // Stale out any in-flight hide — its completion will see a
        // superseded generation and skip the orderOut. `wasHiding` is
        // captured first: a mid-fade re-show should reverse the slide,
        // not restart it from a doubled offset.
        let wasHiding = hideInFlight
        animationGeneration += 1
        hideInFlight = false

        // The resting origin the intro lands on. A mid-fade re-show
        // reverses toward the origin captured when the hide began;
        // a fresh show re-derives geometry under the mouse.
        var restingOrigin = wasHiding
            ? hideRestingOrigin ?? panel.frame.origin
            : panel.frame.origin
        hideRestingOrigin = nil
        if !wasHiding, let screen = screenUnderMouse() {
            let size = NSSize(width: Size.width, height: Size.height)
            restingOrigin = PanelGeometry.panelOrigin(
                inVisibleFrame: screen.visibleFrame, panelSize: size)
            panel.setFrameOrigin(restingOrigin)
        }

        // Already on screen and not fading out (a show() meant just to
        // re-focus)? Replaying the intro would blink the panel and stack
        // another slide offset — take the no-animation path. A mid-fade
        // re-show under Reduce Motion still snaps the frame back.
        let alreadyVisible = panel.isVisible && !wasHiding
        if alreadyVisible || AccessibilityDisplaySettings.shared.reduceMotion {
            if wasHiding {
                // A zero-duration animation replaces the still-running
                // hide fade/slide instead of racing it — direct property
                // sets don't reliably detach an in-flight animation.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    panel.animator().setFrameOrigin(restingOrigin)
                    panel.animator().alphaValue = 1
                }
            }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            // Slide-in from above with fade. A fresh show starts at
            // alpha 0 one offset above the resting origin; a mid-fade
            // re-show keeps the pending hide's model values so the
            // animation targets below simply reverse it.
            if !wasHiding {
                panel.alphaValue = 0
                var startFrame = panel.frame
                startFrame.origin = restingOrigin
                startFrame.origin.y += Animation.slideOffset
                panel.setFrameOrigin(startFrame.origin)
            }
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Animation.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                var targetFrame = panel.frame
                targetFrame.origin = restingOrigin
                panel.animator().setFrame(targetFrame, display: true)
            }
        }

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
            DispatchQueue.main.async { [weak self] in
                if let field = self?.panel?.preferredFirstResponder {
                    self?.panel?.makeFirstResponder(field)
                }
            }
        }
    }

    func hide() {
        panelSession += 1
        // A dismissed panel must not keep working: a `find` walk would
        // scan the disk for minutes, and a `make` generation would keep
        // spending API budget for a result nobody sees. Dismiss is when
        // the user asked — cancel now, not when the fade completes.
        model.panelDidHide()
        // A fade-out is already running toward orderOut — a second one
        // would stack another slideOffset onto the already-offset frame.
        if hideInFlight { return }
        animationGeneration += 1
        guard let panel, panel.isVisible else { return }
        // Capture the pre-fade origin so a mid-fade show() can reverse
        // toward it; `panel.frame` only reaches the offset target when
        // the animation completes.
        hideRestingOrigin = panel.frame.origin

        let reduceMotion = AccessibilityDisplaySettings.shared.reduceMotion
        if reduceMotion {
            panel.orderOut(nil)
            return
        }

        let generation = animationGeneration
        hideInFlight = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Animation.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            var frame = panel.frame
            frame.origin.y += Animation.slideOffset
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // A show() or hide() since this animation started owns the
            // panel now — a superseding show resets alpha itself, and a
            // superseding hide keeps fading, so this completion does
            // nothing at all.
            guard self.animationGeneration == generation else { return }
            self.hideInFlight = false
            panel.orderOut(nil)
            // Restore alpha and the pre-fade origin for the next show —
            // the completed fade left the frame at the offset target.
            panel.alphaValue = 1
            if let resting = self.hideRestingOrigin {
                panel.setFrameOrigin(resting)
            }
            self.hideRestingOrigin = nil
        })
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
