import AppKit
import PictKit
import SwiftUI

/// Hosts the detached file-search window — where a `find`/`f`/`search`
/// session lands when the user presses ⏎ while the walk is still
/// streaming (`PanelModel.submit` → `PanelController`'s detach hook).
/// The window is a persistent results browser: it keeps showing the
/// accumulating matches, offers open/reveal/pin/block, and retires the
/// session only when it closes.
///
/// One window at a time — a new detach while one is open swaps its
/// content and retires the old session.
final class DetachedSearchWindowController: NSObject, NSWindowDelegate {

    private let preferences: Preferences
    private var window: DetachedSearchWindow?
    private var hostingController: NSHostingController<DetachedSearchView>?
    private var model: DetachedSearchModel?

    /// Returns focus to the app that was active before the window took
    /// it — one handoff spans the window's whole visible lifetime, same
    /// as `SettingsWindowController`.
    private var activationHandoff: ActivationHandoff?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Presents `session` in the results window — reusing the open
    /// window when one exists, otherwise building it. A live prior
    /// session is retired: the window can only show one search.
    func show(session: FileSearchSession, entryRules: EntryRules,
              iconResolver: ((IconTarget) -> NSImage?)?) {
        beginActivationHandoff()

        model?.close()
        let model = DetachedSearchModel(session: session,
                                        entryRules: entryRules,
                                        iconResolver: iconResolver)
        model.onSubmit = { ActionPerformer.perform($0) }
        self.model = model

        if let hostingController {
            hostingController.rootView = DetachedSearchView(model: model,
                                                            preferences: preferences)
        } else {
            let hosting = NSHostingController(
                rootView: DetachedSearchView(model: model,
                                             preferences: preferences))
            // Only the SwiftUI content drives the minimum size — guarded
            // for macOS 13, where `sizingOptions` doesn't exist (the
            // Settings window does the same).
            if #available(macOS 14.0, *) { hosting.sizingOptions = [.minSize] }

            let window = DetachedSearchWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 440))
            window.isReleasedWhenClosed = false
            window.delegate = self

            window.onMove = { [weak self] in self?.model?.moveSelection(by: $0) }
            window.onPage = { [weak self] in self?.model?.pageSelection(by: $0) }
            window.onBoundary = { [weak self] boundary in
                self?.model?.selectBoundary(boundary)
            }
            window.onSubmit = { [weak self] in
                self?.model?.submit(commandModifier: $0)
            }
            window.onPinChord = { [weak self] in
                guard let self, let toast = self.model?.togglePin() else { return }
                HUD.show(toast, typeface: self.preferences.panelTypeface)
            }
            window.onBlockChord = { [weak self] in
                guard let self, let toast = self.model?.toggleBlock() else { return }
                HUD.show(toast, typeface: self.preferences.panelTypeface)
            }

            self.hostingController = hosting
            self.window = window
            window.center()
            // The autosave name is set last so a previously-saved frame
            // wins over the default centered position.
            window.setFrameAutosaveName("InvoqueFileSearchWindow")
        }

        window?.title = session.query
        // An accessory app's window doesn't take focus on its own; ask
        // for it — the panel it just detached from was non-activating.
        AppActivator.activateSelfForOwnWindow()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A pin/block made elsewhere — forwarded from `PanelModel`'s
    /// `entryRulesDidChange`, which owns the single-subscriber hook.
    func entryRulesDidChange() {
        model?.refreshRules()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing retires the search — the walk stops with its window.
        model?.close()
        model = nil
        finishActivationHandoff()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        finishActivationHandoff()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        beginActivationHandoff()
    }

    private func beginActivationHandoff() {
        if activationHandoff == nil { activationHandoff = ActivationHandoff() }
    }

    private func finishActivationHandoff() {
        let handoff = activationHandoff
        activationHandoff = nil
        handoff?.restore()
    }
}
