import AppKit

/// The detached file-search window — a plain titled window, unlike the
/// launcher panel's borderless `NSPanel`: it persists after the handoff,
/// takes normal key status, and closes on Esc/⌘W or its close button.
///
/// There's no text field to route keys through, so `keyDown` drives the
/// list directly — the same chord vocabulary as `LauncherPanel`
/// (↑↓ navigate, ⏎ open, ⌘⏎ reveal, ⌘P pin, ⌘B block) plus ⌘W/Esc to
/// close.
final class DetachedSearchWindow: NSWindow {

    /// ↑/↓ by one row. Wired to the model by the window's controller.
    var onMove: ((Int) -> Void)?
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
        case 125: onMove?(1)          // ↓
        case 126: onMove?(-1)         // ↑
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
