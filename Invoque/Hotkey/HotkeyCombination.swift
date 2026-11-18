import Foundation
import KeycapKit

/// A global hotkey: a Carbon virtual key code plus Carbon modifier flags.
///
/// Stored as the raw Carbon values because they are exactly what
/// `RegisterEventHotKey` consumes — deliberately *not* `NSEvent.ModifierFlags`,
/// whose bit layout differs. A single `Codable` value so key code and
/// modifiers always travel (and persist) together.
///
/// This is Invoque's persisted shape only: the combo model, display table and
/// usability rules live in Keycap, and the stored JSON stays
/// `{"keyCode":N,"modifiers":N}`.
struct HotkeyCombination: Codable, Equatable {

    /// Virtual key code — one of the `kVK_*` constants.
    let keyCode: UInt32

    /// Carbon modifier mask — a combination of `cmdKey`, `shiftKey`,
    /// `optionKey`, `controlKey`.
    let modifiers: UInt32

    /// ⌥Space, the default summon hotkey. Carbon hotkeys need no TCC
    /// permission and ⌥Space is unclaimed by the system (PLAN.md §5).
    /// Note this also intercepts ⌥Space used to type a non-breaking space in
    /// other apps — rebind it in Settings if that bites.
    static let `default` = HotkeyCombination(keyCode: KeyCode.space,
                                             modifiers: HotkeyModifiers.option.rawValue)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The Keycap model this persisted value converts to.
    var combo: KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: HotkeyModifiers(carbonFlags: modifiers))
    }

    init(combo: KeyCombo) {
        self.init(keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
    }

    // MARK: Display

    /// "⌥ Space"-style label for Settings. Printable keys are named by the
    /// active keyboard layout so the label matches the physical keycap (a
    /// German board's Y sits at the ANSI Z position: the hotkey records the
    /// position, and the label should name what the user pressed).
    var displayString: String {
        combo.displayString(keyName: KeyNames.displayName(for: keyCode), separator: " ")
    }
}
