import XCTest
import AppKit
@testable import Invoque

final class AdaptiveAccentTests: XCTestCase {

    /// A saturated red square covering half of an otherwise transparent
    /// canvas — the shape of every rounded-rect app icon (color in the middle,
    /// transparency at the corners).
    private func makeHalfRedIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 25, y: 25, width: 50, height: 50).fill()
        image.unlockFocus()
        return image
    }

    /// The sampled accent must be *red* — if the RGBA8 bitmap were read as
    /// straight alpha while actually premultiplied, the transparent half would
    /// drag the average toward black and brightness would crater.
    func testDominantColorOfTranslucentIconStaysBright() {
        let color = makeHalfRedIcon().dominantAccentColor()
        XCTAssertNotNil(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color?.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Hue ~0 (red), full-ish saturation, and — the discriminator —
        // brightness near 1, not the ~0.5 a premultiplied misread produces.
        XCTAssertTrue(h < 0.05 || h > 0.95, "hue \(h) should be red")
        XCTAssertGreaterThan(s, 0.7)
        XCTAssertGreaterThan(b, 0.9)
    }

    /// A fully opaque icon samples identically whether or not the bitmap is
    /// premultiplied — the unpremultiply must be a no-op at alpha = 1.
    func testDominantColorOfOpaqueIconIsUnaffected() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let color = image.dominantAccentColor()
        XCTAssertNotNil(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color?.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        XCTAssertTrue(h > 0.55 && h < 0.75, "hue \(h) should be blue")
        XCTAssertGreaterThan(b, 0.9)
    }
}
