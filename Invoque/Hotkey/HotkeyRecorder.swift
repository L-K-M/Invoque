import AppKit
import KeycapKit
import SwiftUI

/// A click-to-record field for the summon hotkey.
///
/// Idle it shows the current chord ("⌥ Space"); a click or ⏎ arms it and
/// the next key press becomes the binding. Esc cancels, ⌫ restores the
/// default, and a chord without ⌃/⌥/⌘ is refused — a bare or shift-only
/// key would summon the panel mid-typing. Unlike Keycap's stricter
/// `isUsableGlobalHotkey`, ⌘Space stays recordable: a launcher is what
/// people bind there once they turn off Spotlight's shortcut, and bare
/// function keys stay refused because `Preferences` only loads chords with
/// a modifier. Losing first responder disarms, so pressing the *current*
/// hotkey while armed (it fires globally and summons the panel) cancels
/// cleanly instead of dead-locking the field.
struct HotkeyRecorder: NSViewRepresentable {

    @Binding var combination: HotkeyCombination

    func makeNSView(context: Context) -> Field {
        let field = Field(frame: .zero)
        field.onRecord = { combination = $0 }
        field.displayText = combination.displayString
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        field.displayText = combination.displayString
    }

    /// The AppKit half: a bordered, centered field that arms on click and
    /// interprets the next chord while it holds first responder.
    final class Field: NSTextField {

        /// Fires with the captured chord — never on cancel or reject.
        var onRecord: ((HotkeyCombination) -> Void)?

        /// The idle label — the representable syncs the bound
        /// combination's `displayString` into it.
        var displayText = "" {
            didSet { if !armed { stringValue = displayText } }
        }

        private var armed = false {
            didSet {
                textColor = armed ? .controlAccentColor : nil
                updateLabel()
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isEditable = false
            isSelectable = false
            isBordered = true
            bezelStyle = .roundedBezel
            alignment = .center
            font = .systemFont(ofSize: NSFont.systemFontSize)
            setAccessibilityLabel("Summon hotkey recorder")
            setAccessibilityHelp(
                "Activate, then press the new keyboard shortcut")
        }

        required init?(coder: NSCoder) {
            fatalError("HotkeyRecorder is created in code only")
        }

        override var acceptsFirstResponder: Bool { true }

        // MARK: Recording

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            armed = true
        }

        override func keyDown(with event: NSEvent) {
            guard armed else {
                // Keyboard parity with the click: Return/Space arm;
                // everything else falls through for focus traversal.
                if event.keyCode == UInt16(KeyCode.return)
                    || event.keyCode == UInt16(KeyCode.space) {
                    armed = true
                } else {
                    super.keyDown(with: event)
                }
                return
            }
            let modifiers = HotkeyModifiers(eventFlags: event.modifierFlags)
            switch event.keyCode {
            case UInt16(KeyCode.escape):
                cancel()
            // Bare ⌫/⌦ reset to the default — a chorded one (⌥⌫, ⌘⌦)
            // is a legitimate hotkey and must record like any other.
            case UInt16(KeyCode.delete) where modifiers.isEmpty,
                 UInt16(KeyCode.forwardDelete) where modifiers.isEmpty:
                commit(.default)
            default:
                let combo = KeyCombo(
                    keyCode: UInt32(event.keyCode), modifiers: modifiers)
                guard combo.hasCommandingModifier else {
                    NSSound.beep()
                    cancel()
                    return
                }
                commit(HotkeyCombination(combo: combo))
            }
        }

        /// Live modifier preview while armed — holding ⌃⌥ shows "⌃⌥"
        /// until the key lands.
        override func flagsChanged(with event: NSEvent) {
            if armed {
                let glyphs = HotkeyModifiers(
                    eventFlags: event.modifierFlags).symbols
                stringValue = glyphs.isEmpty ? "Type shortcut…" : glyphs
            }
            super.flagsChanged(with: event)
        }

        /// Focus loss disarms: covers click-away and the current hotkey
        /// firing the panel (which resigns this window's key status).
        override func resignFirstResponder() -> Bool {
            armed = false
            return super.resignFirstResponder()
        }

        private func commit(_ combination: HotkeyCombination) {
            armed = false
            onRecord?(combination)
            window?.makeFirstResponder(nil)
        }

        private func cancel() {
            armed = false
            window?.makeFirstResponder(nil)
        }

        private func updateLabel() {
            stringValue = armed ? "Type shortcut…" : displayText
        }
    }
}
