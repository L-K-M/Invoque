import Foundation
import Carbon.HIToolbox

/// A global hotkey: a Carbon virtual key code plus Carbon modifier flags.
///
/// Stored as the raw Carbon values because they are exactly what
/// `RegisterEventHotKey` consumes — deliberately *not* `NSEvent.ModifierFlags`,
/// whose bit layout differs. A single `Codable` value so key code and
/// modifiers always travel (and persist) together.
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
    static let `default` = HotkeyCombination(keyCode: UInt32(kVK_Space),
                                             modifiers: UInt32(optionKey))

    // MARK: Display

    /// Canonical "⌃⌥⇧⌘" glyph run for a Carbon modifier mask, in menu
    /// order (control, option, shift, command).
    static func modifierGlyphs(_ carbonModifiers: UInt32) -> String {
        var glyphs = ""
        if carbonModifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        return glyphs
    }

    /// "⌥ Space"-style label for Settings. Named keys come from the table
    /// below; printable keys translate through the active keyboard layout
    /// so the label matches the physical keycap (a German board's Y sits
    /// at the ANSI Z position — the hotkey records the position, and the
    /// label should name what the user pressed).
    var displayString: String {
        let modifiers = Self.modifierGlyphs(modifiers)
        let key = Self.keyNames[Int(keyCode)]
            ?? Self.translatedCharacter(for: keyCode)
            ?? "Key \(keyCode)"
        return modifiers.isEmpty ? key : "\(modifiers) \(key)"
    }

    /// Display names for keys whose character isn't printable or reads
    /// ambiguously. Indexed by Carbon virtual key code.
    private static let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_Help: "Help", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_KeypadClear: "⌧", kVK_ANSI_KeypadEnter: "⌅",
    ]

    /// The character `keyCode` types on the active layout, uppercased, or
    /// nil for non-printable keys (they have `keyNames` entries instead).
    private static func translatedCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let property = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(UnsafeRawPointer(property))
            .takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()),
            OptionBits(UInt32(kUCKeyTranslateNoDeadKeysMask)),
            &deadKeys, buffer.count, &length, &buffer)
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: buffer, count: length)
        // Control/whitespace results belong to named keys, not glyphs.
        guard string.rangeOfCharacter(
                from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        return string.uppercased()
    }
}
