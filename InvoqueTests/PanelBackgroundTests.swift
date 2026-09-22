import AppKit
import SwiftUI
import XCTest
@testable import Invoque

final class PanelBackgroundTests: XCTestCase {

    @MainActor
    func testReduceTransparencyRemovesVisualEffectBlur() {
        let regular = host(reduceTransparency: false)
        let reduced = host(reduceTransparency: true)

        #if compiler(>=6.2)
        if #unavailable(macOS 26.0) {
            XCTAssertTrue(containsVisualEffectView(regular))
        }
        #else
        XCTAssertTrue(containsVisualEffectView(regular))
        #endif
        XCTAssertFalse(containsVisualEffectView(reduced))
    }

    /// `NSHostingView` internals are Apple's implementation detail: if an OS
    /// update starts vending `NSVisualEffectView` under `glassEffect`, check
    /// whether it is still native glass before treating it as app fallback.
    /// Kept apart from the behavior tests so that future flip fails alone.
    @MainActor
    func testNativeGlassDoesNotVendVisualEffectView() throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26")
        }
        XCTAssertFalse(
            containsVisualEffectView(host(reduceTransparency: false)),
            "Expected native glassEffect without an NSVisualEffectView")
        #else
        throw XCTSkip("Requires the macOS 26 SDK")
        #endif
    }

    @MainActor
    func testReduceTransparencyRemovesBlurForEveryGlassMaterial() {
        for material in [PanelMaterial.liquidGlass, .glassClear, .glassTinted] {
            XCTAssertFalse(containsVisualEffectView(host(
                material: material,
                reduceTransparency: true)), "unexpected blur for \(material)")
        }
    }

    func testFallbackTintWashAppliesOnlyToTintedGlass() {
        XCTAssertNil(PanelBackground.fallbackTintOpacity(
            for: .liquidGlass, configuredOpacity: 0.9))
        XCTAssertNil(PanelBackground.fallbackTintOpacity(
            for: .glassClear, configuredOpacity: 0.9))
    }

    func testFallbackTintWashClampsToHalf() {
        XCTAssertEqual(PanelBackground.fallbackTintOpacity(
            for: .glassTinted, configuredOpacity: 0.0), 0.0)
        XCTAssertEqual(PanelBackground.fallbackTintOpacity(
            for: .glassTinted, configuredOpacity: 0.5), 0.5)
        XCTAssertEqual(PanelBackground.fallbackTintOpacity(
            for: .glassTinted, configuredOpacity: -0.3), 0.0)
        XCTAssertEqual(PanelBackground.fallbackTintOpacity(
            for: .glassTinted, configuredOpacity: 0.9), 0.5)
    }

    @MainActor
    private func host(
        material: PanelMaterial = .liquidGlass,
        reduceTransparency: Bool
    ) -> NSHostingView<PanelBackground> {
        let view = NSHostingView(rootView: PanelBackground(
            material: material,
            tint: .black,
            gradientColor: .gray,
            gradientAngle: 0,
            opacity: 0.9,
            cornerRadius: 20,
            reduceTransparency: reduceTransparency))
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 440)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @MainActor
    private func containsVisualEffectView(_ view: NSView) -> Bool {
        if view is NSVisualEffectView { return true }
        return view.subviews.contains(where: containsVisualEffectView)
    }
}
