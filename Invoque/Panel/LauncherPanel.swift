import AppKit

/// The summonable launcher window.
///
/// Borderless for the Spotlight look (no title bar), `.nonactivatingPanel` so
/// it can take keyboard focus without activating Invoque and stay out of the
/// user's way. The SwiftUI card inside (`PanelView`) draws everything visible.
///
/// Dismissal on losing key status is *not* handled here: `PanelController`
/// observes `NSWindow.didResignKeyNotification` for this panel and owns hiding
/// — the controller owns dismissal, the window only reports cancellation.
final class LauncherPanel: NSPanel {

    /// Invoked when the user cancels — Esc sent up the responder chain from
    /// the focused search field. The controller decides what cancel means.
    var onCancel: (() -> Void)?

    /// The view that should hold keyboard focus whenever the panel is
    /// summoned. The search field registers itself here (see `SearchTextField`
    /// in PanelView); `PanelController.show` makes it first responder. Weak, so
    /// it can never outlive the SwiftUI hierarchy that owns it.
    weak var preferredFirstResponder: NSView?

    /// A borderless panel would not become key by default; the panel must
    /// become key to receive typing, which is the whole point of summoning it.
    override var canBecomeKey: Bool { true }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)

        // Float over most things, appear on every Space, and stay put (and
        // reachable) while a fullscreen app is frontmost.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // The rounded card drawn by SwiftUI is the only visible surface; the
        // window itself is a transparent cutout.
        isOpaque = false
        backgroundColor = .clear

        // We hide on key-resign ourselves (see class comment); AppKit's
        // deactivate-driven hiding would fire on unrelated app switches.
        hidesOnDeactivate = false

        // The panel is reused for every summon, never destroyed per show.
        isReleasedWhenClosed = false
    }

    /// Esc from the focused field travels the responder chain to here.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
