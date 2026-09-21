import XCTest
import Carbon.HIToolbox
@testable import Invoque

final class HotkeyCombinationTests: XCTestCase {

    func testDefaultIsOptionSpace() {
        XCTAssertEqual(HotkeyCombination.default,
                       HotkeyCombination(keyCode: UInt32(kVK_Space),
                                         modifiers: UInt32(optionKey)))
        // The concrete values, so a surprising SDK constant is caught here
        // rather than as a mis-registered hotkey.
        XCTAssertEqual(HotkeyCombination.default.keyCode, 49)
        XCTAssertEqual(HotkeyCombination.default.modifiers, 1 << 11)
    }

    func testCodableRoundTrip() throws {
        let original = HotkeyCombination(keyCode: UInt32(kVK_Return),
                                         modifiers: UInt32(cmdKey | shiftKey))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyCombination.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testModifierGlyphsOrderAndCompleteMask() {
        XCTAssertEqual(
            HotkeyCombination.modifierGlyphs(
                UInt32(cmdKey | shiftKey | optionKey | controlKey)),
            "⌃⌥⇧⌘")
        XCTAssertEqual(HotkeyCombination.modifierGlyphs(0), "")
    }

    func testDisplayStringNamesNamedKeys() {
        XCTAssertEqual(HotkeyCombination.default.displayString, "⌥ Space")
        XCTAssertEqual(
            HotkeyCombination(keyCode: UInt32(kVK_F5),
                              modifiers: UInt32(cmdKey | shiftKey))
                .displayString,
            "⇧⌘ F5")
        XCTAssertEqual(
            HotkeyCombination(keyCode: UInt32(kVK_UpArrow),
                              modifiers: UInt32(controlKey))
                .displayString,
            "⌃ ↑")
    }

    /// Letter keys render through the active keyboard layout — the
    /// assertion only holds where ANSI-A actually types "A" (US on CI).
    /// AZERTY prints "Q", and layout-less input sources yield "Key 0".
    func testDisplayStringTranslatesPrintableKeys() throws {
        let bareA = HotkeyCombination(keyCode: UInt32(kVK_ANSI_A),
                                      modifiers: 0)
        try XCTSkipUnless(bareA.displayString == "A",
                          "Active layout doesn't map ANSI-A to 'A'")
        XCTAssertEqual(
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_A),
                              modifiers: UInt32(optionKey))
                .displayString,
            "⌥ A")
    }

    func testDisplayStringFallsBackForUnknownKeyCode() {
        // Past every real virtual key code: no table entry, no
        // translation — a legible fallback, never a crash.
        XCTAssertEqual(
            HotkeyCombination(keyCode: 500, modifiers: UInt32(cmdKey))
                .displayString,
            "⌘ Key 500")
    }
}
