import AppKit
import XCTest
@testable import Invoque

final class PanelGeometryTests: XCTestCase {

    func testCenteredAndQuarterDownOnMainScreen() {
        // Visible frame of a 1920×1080 display with the 25pt menu bar.
        let visibleFrame = NSRect(x: 0, y: 25, width: 1920, height: 1055)
        let panelSize = NSSize(width: 680, height: 440)

        let origin = PanelGeometry.panelOrigin(inVisibleFrame: visibleFrame, panelSize: panelSize)

        // Horizontally centered in the visible frame.
        XCTAssertEqual(origin.x, visibleFrame.midX - panelSize.width / 2, accuracy: 0.001)
        // Top edge a quarter of the visible height below the frame's top.
        XCTAssertEqual(origin.y + panelSize.height,
                       visibleFrame.maxY - visibleFrame.height / 4,
                       accuracy: 0.001)
        // And therefore fully inside the visible frame.
        XCTAssertTrue(visibleFrame.contains(NSRect(origin: origin, size: panelSize)))
    }

    func testOffsetDisplayOriginIsRelativeToThatDisplay() {
        // A display positioned to the right of the built-in one: its global
        // coordinates don't start at zero, and placement must be relative to
        // *this* display's frame, not the zero-origin one.
        let visibleFrame = NSRect(x: 1440, y: 0, width: 1512, height: 982)
        let panelSize = NSSize(width: 680, height: 440)

        let origin = PanelGeometry.panelOrigin(inVisibleFrame: visibleFrame, panelSize: panelSize)

        XCTAssertEqual(origin.x, 1440 + (1512 - 680) / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, 982 * 0.75 - 440, accuracy: 0.001)
    }

    func testTallPanelStillSitsInsideVisibleFrame() {
        // A panel as tall as the space below the top edge lands exactly on the
        // visible frame's bottom edge — never under the Dock area.
        let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let panelSize = NSSize(width: 800, height: 450)

        let origin = PanelGeometry.panelOrigin(inVisibleFrame: visibleFrame, panelSize: panelSize)

        XCTAssertEqual(origin.y, visibleFrame.minY, accuracy: 0.001)
        XCTAssertEqual(origin.x, visibleFrame.minX, accuracy: 0.001)
    }
}
