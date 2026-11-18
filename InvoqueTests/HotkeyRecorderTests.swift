import AppKit
import KeycapKit
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
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        XCTAssertEqual(field.stringValue, "Type shortcut…")
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.x),
                                         modifiers: [.command, .option]))
        XCTAssertEqual(box.value, HotkeyCombination(
            keyCode: UInt32(KeyCode.x),
            modifiers: HotkeyModifiers([.command, .option]).rawValue))
    }

    func testEscapeCancelsWithoutRecording() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.escape)))
        XCTAssertNil(box.value)
        XCTAssertEqual(field.stringValue, "⌥ Space")
    }

    func testBareKeyIsRejectedNotRecorded() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.a)))
        XCTAssertNil(box.value)
        XCTAssertEqual(field.stringValue, "⌥ Space")
    }

    func testShiftOnlyChordIsRejected() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.a),
                                         modifiers: [.shift]))
        XCTAssertNil(box.value)
    }

    /// A launcher is what people bind to ⌘Space once Spotlight's shortcut
    /// is off, so Invoque keeps it recordable even though Keycap's shared
    /// `isUsableGlobalHotkey` treats it as system-reserved.
    func testCommandSpaceRecords() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.space),
                                         modifiers: [.command]))
        XCTAssertEqual(box.value, HotkeyCombination(
            keyCode: UInt32(KeyCode.space),
            modifiers: HotkeyModifiers.command.rawValue))
    }

    /// A bare function key is refused like any bare key: `Preferences`
    /// only loads stored chords that carry a modifier.
    func testBareFunctionKeyIsRejected() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.f5)))
        XCTAssertNil(box.value)
    }

    func testDeleteRestoresDefault() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.delete)))
        XCTAssertEqual(box.value, .default)
    }

    /// A chorded Delete is a real hotkey — only a bare ⌫ resets.
    func testModifiedDeleteRecordsAsChord() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.delete),
                                         modifiers: [.option]))
        XCTAssertEqual(box.value, HotkeyCombination(
            keyCode: UInt32(KeyCode.delete),
            modifiers: HotkeyModifiers.option.rawValue))
    }

    /// Symmetric with ⌥⌫: the per-pattern `where` guard must hold for
    /// ForwardDelete too — a shared trailing `where` broke exactly that.
    func testModifiedForwardDeleteRecordsAsChord() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.forwardDelete),
                                         modifiers: [.command]))
        XCTAssertEqual(box.value, HotkeyCombination(
            keyCode: UInt32(KeyCode.forwardDelete),
            modifiers: HotkeyModifiers.command.rawValue))
    }

    func testResignFirstResponderDisarms() {
        let (field, box) = makeField()
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.return)))
        _ = field.resignFirstResponder()
        // Now unarmed: a chord must not record.
        field.keyDown(with: keyDownEvent(UInt16(KeyCode.x),
                                         modifiers: [.command]))
        XCTAssertNil(box.value)
    }
}
