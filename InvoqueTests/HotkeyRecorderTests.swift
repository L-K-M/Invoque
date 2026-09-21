import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Invoque

final class HotkeyRecorderTests: XCTestCase {

    private func keyDownEvent(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        // characters only has to parse; the field reads keyCode + flags.
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil,
                         characters: "x", charactersIgnoringModifiers: "x",
                         isARepeat: false, keyCode: keyCode)!
    }

    private func makeField() -> (HotkeyRecorder.Field, LockedBox) {
        let field = HotkeyRecorder.Field(frame: .zero)
        field.displayText = "⌥ Space"
        let box = LockedBox()
        field.onRecord = { box.value = $0 }
        return (field, box)
    }

    /// Closure capture needs a reference box — the field records into it.
    final class LockedBox {
        var value: HotkeyCombination?
    }

    func testReturnArmsThenChordRecords() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(kVK_Return)))
        XCTAssertEqual(field.stringValue, "Type shortcut…")
        field.keyDown(with: keyDownEvent(UInt16(kVK_ANSI_X),
                                         modifiers: [.command, .option]))
        XCTAssertEqual(box.value, HotkeyCombination(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: UInt32(cmdKey | optionKey)))
    }

    func testEscapeCancelsWithoutRecording() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(kVK_Return)))
        field.keyDown(with: keyDownEvent(UInt16(kVK_Escape)))
        XCTAssertNil(box.value)
        XCTAssertEqual(field.stringValue, "⌥ Space")
    }

    func testBareKeyIsRejectedNotRecorded() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(kVK_Return)))
        field.keyDown(with: keyDownEvent(UInt16(kVK_ANSI_A)))
        XCTAssertNil(box.value)
        XCTAssertEqual(field.stringValue, "⌥ Space")
    }

    func testShiftOnlyChordIsRejected() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(kVK_Return)))
        field.keyDown(with: keyDownEvent(UInt16(kVK_ANSI_A),
                                         modifiers: [.shift]))
        XCTAssertNil(box.value)
    }

    func testDeleteRestoresDefault() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(kVK_Return)))
        field.keyDown(with: keyDownEvent(UInt16(kVK_Delete)))
        XCTAssertEqual(box.value, .default)
    }

    func testResignFirstResponderDisarms() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(kVK_Return)))
        _ = field.resignFirstResponder()
        // Now unarmed: a chord must not record.
        field.keyDown(with: keyDownEvent(UInt16(kVK_ANSI_X),
                                         modifiers: [.command]))
        XCTAssertNil(box.value)
    }

    func testModifierFlagsMapToCarbonMask() {
        XCTAssertEqual(
            HotkeyRecorder.carbonModifiers(of: [.command, .shift]),
            UInt32(cmdKey | shiftKey))
        XCTAssertEqual(
            HotkeyRecorder.carbonModifiers(
                of: [.control, .option, .shift, .command]),
            UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(HotkeyRecorder.carbonModifiers(of: []), 0)
    }

    func testRecordableRequiresNonShiftModifier() {
        XCTAssertTrue(HotkeyRecorder.isRecordable(
            modifiers: UInt32(optionKey)))
        XCTAssertTrue(HotkeyRecorder.isRecordable(
            modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertFalse(HotkeyRecorder.isRecordable(modifiers: 0))
        XCTAssertFalse(HotkeyRecorder.isRecordable(
            modifiers: UInt32(shiftKey)))
    }
}
