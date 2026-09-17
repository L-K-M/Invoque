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
    private let model: PanelModel
    private var panel: LauncherPanel?
    private var resignKeyObserver: NSObjectProtocol?

    init(preferences: Preferences) {
        self.preferences = preferences
        let model = PanelModel()
        self.model = model
        super.init()

        // Milestone 1: any submit just dismisses. Real action dispatch (open
        // app, run command, …) arrives with the search glue.
        model.onSubmit = { [weak self] _ in self?.hide() }
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
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Panel lifecycle

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Size.width, height: Size.height))
        panel.contentView = NSHostingView(rootView: PanelView(model: model))

        panel.onCancel = { [weak self] in self?.hide() }

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
