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
        if #available(macOS 26.0, *) {
            // If this changes after an OS update, re-check whether glassEffect
            // began vending NSVisualEffectView before treating it as app fallback.
            XCTAssertFalse(
                containsVisualEffectView(regular),
                "Expected native glassEffect without an NSVisualEffectView")
        } else {
            XCTAssertTrue(containsVisualEffectView(regular))
        }
        #else
        XCTAssertTrue(containsVisualEffectView(regular))
        #endif
        XCTAssertFalse(containsVisualEffectView(reduced))
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
