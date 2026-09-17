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
}
