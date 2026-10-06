import CoreGraphics
import XCTest
@testable import Invoque

final class WindowServerVisibilityTests: XCTestCase {
    func testOnscreenWindowIsHealthyEvenWhenOtherWindowsArePresent() {
        let windows: [[String: Any]] = [
            [kCGWindowNumber as String: 7, kCGWindowIsOnscreen as String: false],
            [kCGWindowNumber as String: 42, kCGWindowIsOnscreen as String: true]
        ]
        XCTAssertEqual(WindowServerVisibility.isOnscreen(42, in: windows), true)
    }

    func testOffscreenAndMissingWindowsConfirmFailure() {
        XCTAssertEqual(WindowServerVisibility.isOnscreen(42, in: [
            [kCGWindowNumber as String: 42, kCGWindowIsOnscreen as String: false]
        ]), false)
        XCTAssertEqual(WindowServerVisibility.isOnscreen(42, in: []), false)
        XCTAssertEqual(WindowServerVisibility.isOnscreen(42, in: [
            [kCGWindowNumber as String: 7, kCGWindowIsOnscreen as String: true]
        ]), false)
        XCTAssertEqual(WindowServerVisibility.isOnscreen(42, in: [
            [kCGWindowNumber as String: 42]
        ]), false, "CoreGraphics omits this key when a window is not ordered onscreen")
    }

    func testUncreatedWindowIsUnknown() {
        XCTAssertNil(WindowServerVisibility.isOnscreen(0))
        XCTAssertNil(WindowServerVisibility.isOnscreen(-1))
    }
}
