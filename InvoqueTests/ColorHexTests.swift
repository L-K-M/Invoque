import XCTest
import SwiftUI
@testable import Invoque

final class ColorHexTests: XCTestCase {

    // MARK: RGBA8 parsing

    func testParsesSixDigitHex() {
        let c = RGBA8(hex: "#FF8800")
        XCTAssertEqual(c?.red, 0xFF)
        XCTAssertEqual(c?.green, 0x88)
        XCTAssertEqual(c?.blue, 0x00)
        XCTAssertEqual(c?.alpha, 0xFF)
    }

    func testParsesEightDigitHexWithAlpha() {
        let c = RGBA8(hex: "#10203040")
        XCTAssertEqual(c?.alpha, 0x40)
    }

    func testParsesShorthandAndMissingHash() {
        XCTAssertEqual(RGBA8(hex: "#abc"), RGBA8(hex: "#AABBCC"))
        XCTAssertEqual(RGBA8(hex: "FF8800"), RGBA8(hex: "#FF8800"))
    }

    func testRejectsInvalidHex() {
        XCTAssertNil(RGBA8(hex: ""))
        XCTAssertNil(RGBA8(hex: "#12"))
        XCTAssertNil(RGBA8(hex: "#GGGGGG"))
        XCTAssertNil(RGBA8(hex: "+12345"))
    }

    func testHexStringRoundTrips() {
        XCTAssertEqual(RGBA8(hex: "#B18CFF")?.hexString, "#B18CFF")
        XCTAssertEqual(RGBA8(hex: "#B18CFF80")?.hexString, "#B18CFF80")
    }

    func testClampingInitHandlesWideGamut() {
        let c = RGBA8(clampingRed: 1.4, green: -0.2, blue: 0.5, alpha: .nan)
        XCTAssertEqual(c.red, 255)
        XCTAssertEqual(c.green, 0)
        XCTAssertEqual(c.blue, 128)
        XCTAssertEqual(c.alpha, 0)   // NaN → 0, not a trap
    }

    // MARK: readableForeground

    func testReadableForegroundPicksByLuminance() {
        XCTAssertEqual(Color.readableForeground(on: NSColor(hex: "#FFFFFF") ?? .white),
                       .black)
        XCTAssertEqual(Color.readableForeground(on: NSColor(hex: "#1C1C1E") ?? .black),
                       .white)
        XCTAssertEqual(Color.readableForeground(on: NSColor(hex: "#0A84FF") ?? .blue),
                       .black)
    }

    func testSaturatedHighlightsChooseTheHigherContrastForeground() throws {
        for hex in ["#00FF00", "#00FFFF", "#FF0000", "#808080"] {
            let color = try XCTUnwrap(NSColor(hex: hex))
            XCTAssertEqual(Color.readableForeground(on: color), .black, hex)
        }
        XCTAssertEqual(Color.readableForeground(on: try XCTUnwrap(NSColor(hex: "#0000FF"))),
                       .white)
    }

    // MARK: composited

    func testCompositeAtFullOpacityReturnsTop() {
        let top = NSColor(hex: "#FF0000") ?? .red
        let base = NSColor(hex: "#0000FF") ?? .blue
        let c = top.composited(alpha: 1, over: base).usingColorSpace(.sRGB)
        XCTAssertEqual(c?.redComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(c?.blueComponent ?? 0, 0, accuracy: 0.01)
    }

    func testCompositeAtHalfOpacityBlends() {
        let top = NSColor(hex: "#FFFFFF") ?? .white
        let base = NSColor.black
        let c = top.composited(alpha: 0.5, over: base).usingColorSpace(.sRGB)
        XCTAssertEqual(c?.redComponent ?? 0, 0.5, accuracy: 0.01)
    }

    func testCompositeMultipliesIntrinsicAlphaByConfiguredOpacity() throws {
        let top = try XCTUnwrap(NSColor(hex: "#FFFFFF80"))
        let c = try XCTUnwrap(top.composited(alpha: 0.5, over: .black).usingColorSpace(.sRGB))
        XCTAssertEqual(c.redComponent, 0.5 * 128 / 255, accuracy: 0.001)
        XCTAssertEqual(c.greenComponent, c.redComponent, accuracy: 0.001)
        XCTAssertEqual(c.blueComponent, c.redComponent, accuracy: 0.001)
        XCTAssertEqual(c.alphaComponent, 1)
    }

    func testTransparentHighlightKeepsBackgroundAndReadableForeground() throws {
        let top = try XCTUnwrap(NSColor(hex: "#FFFFFF00"))
        let c = try XCTUnwrap(top.composited(alpha: 1, over: .black).usingColorSpace(.sRGB))
        XCTAssertEqual(c.redComponent, 0)
        XCTAssertEqual(c.greenComponent, 0)
        XCTAssertEqual(c.blueComponent, 0)
        XCTAssertEqual(Color.readableForeground(on: c), .white)
    }

    // MARK: PanelMaterial flags

    func testMaterialTintAndOpacityUsage() {
        XCTAssertFalse(PanelMaterial.liquidGlass.usesTintAndOpacity)
        XCTAssertFalse(PanelMaterial.glassClear.usesTintAndOpacity)
        XCTAssertTrue(PanelMaterial.glassTinted.usesTintAndOpacity)
        XCTAssertTrue(PanelMaterial.solid.usesTintAndOpacity)
        XCTAssertTrue(PanelMaterial.gradient.usesTintAndOpacity)
    }

    func testThemeTextOnlyOnOwnedBackgrounds() {
        // Glass defers to the system text color; solid/gradient own the bg and
        // must own the foreground too.
        XCTAssertFalse(PanelMaterial.liquidGlass.usesThemeTextColor)
        XCTAssertFalse(PanelMaterial.glassClear.usesThemeTextColor)
        XCTAssertFalse(PanelMaterial.glassTinted.usesThemeTextColor)
        XCTAssertTrue(PanelMaterial.solid.usesThemeTextColor)
        XCTAssertTrue(PanelMaterial.gradient.usesThemeTextColor)
    }

    // MARK: Accessibility rules

    func testReduceTransparencyForcesOpaque() {
        XCTAssertEqual(AccessibilityDisplaySettings
            .effectiveBackgroundOpacity(configured: 0.4, reduceTransparency: true), 1)
        XCTAssertEqual(AccessibilityDisplaySettings
            .effectiveBackgroundOpacity(configured: 0.4, reduceTransparency: false), 0.4)
    }

    func testReduceMotionDropsAnimation() {
        XCTAssertNil(AccessibilityDisplaySettings
            .effectiveAnimation(.easeOut, reduceMotion: true))
        XCTAssertNotNil(AccessibilityDisplaySettings
            .effectiveAnimation(.easeOut, reduceMotion: false))
    }
}
