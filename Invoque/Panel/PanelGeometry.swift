import AppKit

/// Pure placement math for the launcher panel. Kept free of window and screen
/// objects so the Spotlight position is unit-testable.
enum PanelGeometry {

    /// How far the panel's top edge sits below the top of the visible frame,
    /// as a fraction of the visible frame's height. Spotlight sits roughly a
    /// quarter of the way down (PLAN.md §3).
    private static let topEdgeFraction: CGFloat = 0.25

    /// The panel origin for a screen's visible frame: horizontally centered,
    /// top edge `topEdgeFraction` down the visible frame.
    ///
    /// - Parameters:
    ///   - visibleFrame: the screen's visible frame (menu bar and Dock
    ///     already excluded) in global coordinates.
    ///   - panelSize: the panel's fixed content size.
    static func panelOrigin(inVisibleFrame visibleFrame: NSRect, panelSize: NSSize) -> NSPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let topEdge = visibleFrame.maxY - visibleFrame.height * topEdgeFraction
        return NSPoint(x: x, y: topEdge - panelSize.height)
    }
}
