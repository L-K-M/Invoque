import AppKit
import SwiftUI
import XCTest
@testable import Invoque

final class PanelBackgroundTests: XCTestCase {

    @MainActor
    func testReduceTransparencyRemovesVisualEffectBlur() {
        let regular = host(reduceTransparency: false)
        let reduced = host(reduceTransparency: true)

        XCTAssertTrue(containsVisualEffectView(regular))
        XCTAssertFalse(containsVisualEffectView(reduced))
    }

    @MainActor
    private func host(reduceTransparency: Bool) -> NSHostingView<PanelBackground> {
        let view = NSHostingView(rootView: PanelBackground(
            material: .liquidGlass,
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
