import CoreGraphics
import Foundation

/// Queries native ordering independently of NSWindow.isVisible. An ordered
/// window can retain an opaque, correctly sized host while Spaces keeps it offscreen.
enum WindowServerVisibility {
    static func isOnscreen(_ windowNumber: Int) -> Bool? {
        guard windowNumber > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow,
                                                      CGWindowID(windowNumber)) as? [[String: Any]] else {
            return nil
        }
        return isOnscreen(windowNumber, in: windows)
    }

    /// A successful query with no matching native window confirms missing ordering.
    /// CoreGraphics defines an absent onscreen key as offscreen, not unknown.
    static func isOnscreen(_ windowNumber: Int, in windows: [[String: Any]]) -> Bool? {
        guard let window = windows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == windowNumber
        }) else { return false }
        return window[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}
