import AppKit

/// Pure placement math for the launcher panel. Kept free of window and screen
/// objects so the Spotlight position is unit-testable.
enum PanelGeometry {

    /// How far the panel's top edge sits below the top of the visible frame,
    /// as a fraction of the visible frame's height. Spotlight sits roughly a
    /// quarter of the way down (PLAN.md §3).
    private static let topEdgeFraction: CGFloat = 0.25

    /// The panel origin for a screen's visible frame: horizontally centered,
    /// top edge `topEdgeFraction` down the visible frame, clamped so the whole
    /// panel stays inside the frame. The clamp matters on short displays
    /// (Dock + menu bar on a small or scaled screen can leave less than
    /// `panelHeight + 25%` of visible height) and if the panel ever exceeds
    /// the frame on either axis.
    ///
    /// - Parameters:
    ///   - visibleFrame: the screen's visible frame (menu bar and Dock
    ///     already excluded) in global coordinates.
    ///   - panelSize: the panel's fixed content size.
    static func panelOrigin(inVisibleFrame visibleFrame: NSRect, panelSize: NSSize) -> NSPoint {
        let centeredX = visibleFrame.midX - panelSize.width / 2
        let topEdge = visibleFrame.maxY - visibleFrame.height * topEdgeFraction
        // A panel larger than the frame on an axis can't satisfy the clamp;
        // pinning to the frame's min keeps as much onscreen as possible.
        let x = min(max(visibleFrame.minX, centeredX),
                  max(visibleFrame.minX, visibleFrame.maxX - panelSize.width))
        let y = min(max(visibleFrame.minY, topEdge - panelSize.height),
                    max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        return NSPoint(x: x, y: y)
    }
}
