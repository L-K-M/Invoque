import AppKit

/// The detached file-search window — a plain titled window, unlike the
/// launcher panel's borderless `NSPanel`: it persists after the handoff,
/// takes normal key status, and closes on Esc/⌘W or its close button.
///
/// There's no text field to route keys through, so `keyDown` drives the
/// list directly — the same chord vocabulary as `LauncherPanel`
/// (↑↓ navigate, ⏎ open, ⌘⏎ reveal, ⌘P pin, ⌘B block) plus the
/// browser keys a persistent window earns (PgUp/PgDn, Home/End, ⌘↑/⌘↓)
/// and ⌘W/Esc to close.
final class DetachedSearchWindow: NSWindow {

    /// ↑/↓ by one row. Wired to the model by the window's controller.
    var onMove: ((Int) -> Void)?
    /// Page Up/Down — the model clamps the jump at the list ends.
    var onPage: ((Int) -> Void)?
    /// Home/End and ⌘↑/⌘↓ — jump to a boundary row. Uses the model's
    /// `Boundary` vocabulary directly — this window exists only for
    /// `DetachedSearchModel`, so a second enum would just mirror it.
    var onBoundary: ((DetachedSearchModel.Boundary) -> Void)?
    /// ⏎ on the selection — `true` when ⌘ was held (reveal in Finder).
    var onSubmit: ((Bool) -> Void)?
    /// ⌘P / ⌘B — pin and block the selected entry.
    var onPinChord: (() -> Void)?
    var onBlockChord: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w":
                close()
                return
            case "p":
                if !event.isARepeat { onPinChord?() }
                return
            case "b":
                if !event.isARepeat { onBlockChord?() }
                return
            default:
                break
            }
        }
        switch event.keyCode {
        case 125:                     // ↓ — ⌘↓ jumps to the last row
            modifiers.contains(.command) ? onBoundary?(.last) : onMove?(1)
        case 126:                     // ↑ — ⌘↑ jumps to the first row
            modifiers.contains(.command) ? onBoundary?(.first) : onMove?(-1)
        case 115: onBoundary?(.first) // home
        case 119: onBoundary?(.last)  // end
        case 116: onPage?(-1)         // page up
        case 121: onPage?(1)          // page down
        case 36, 76:                  // return, keypad enter
            // Unlike the launcher panel, submitting doesn't dismiss this
            // window — a held ⏎ would re-fire at the repeat rate.
            if !event.isARepeat {
                onSubmit?(modifiers.contains(.command))
            }
        case 53: close()              // esc
        default: super.keyDown(with: event)
        }
    }
}
