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

    /// ⌘P pins, ⌘B blocks, ⌘C copies — the selected entry. Wired by the
    /// controller; the model decides whether the chord applies.
    var onPinChord: (() -> Void)?
    var onBlockChord: (() -> Void)?
    var onCopyChord: (() -> Void)?

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

    /// ⌘-chords land here during key dispatch — after the focused field
    /// declines them, before the main menu sees them. ⌘P/⌘B/⌘C are ours
    /// outright: they have no other meaning in a plain search field, and
    /// claiming them unconditionally keeps a no-op chord from beeping.
    /// ⌘C's one exception: a text selection in the search field (or a
    /// Maker input) keeps the normal copy — the Edit menu handles it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p":
                // Repeats are claimed but don't re-toggle — an unclaimed
                // repeat would fall through to the menu and beep.
                if !event.isARepeat { onPinChord?() }
                return true
            case "b":
                if !event.isARepeat { onBlockChord?() }
                return true
            case "c":
                if ((firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0 {
                    return super.performKeyEquivalent(with: event)
                }
                if !event.isARepeat { onCopyChord?() }
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
