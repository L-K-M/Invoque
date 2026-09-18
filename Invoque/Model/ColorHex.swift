import AppKit
import SwiftUI

// The hex format itself lives in `RGBA8` — pure and unit-testable, because it is
// a storage format every build has to agree on. What is left here is the part
// that genuinely needs a colour framework: converting to and from a live
// `NSColor`, and picking a legible foreground for a themed fill.

// MARK: - NSColor hex support

extension NSColor {
    /// Parses `#RRGGBB`, `#RRGGBBAA`, or the CSS shorthands `#RGB`/`#RGBA`
    /// (the leading `#` is optional).
    convenience init?(hex: String) {
        guard let c = RGBA8(hex: hex) else { return nil }
        self.init(srgbRed: CGFloat(c.red) / 255,
                  green: CGFloat(c.green) / 255,
                  blue: CGFloat(c.blue) / 255,
                  alpha: CGFloat(c.alpha) / 255)
    }

    /// `#RRGGBB` (fully opaque) or `#RRGGBBAA` (translucent) in the sRGB color space.
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        // `RGBA8.init(clampingRed:...)` carries the clamp: wide-gamut sources can report
        // components outside 0...1 even after `.sRGB`.
        return RGBA8(clampingRed: Double(c.redComponent),
                     green: Double(c.greenComponent),
                     blue: Double(c.blueComponent),
                     alpha: Double(c.alphaComponent)).hexString
    }

    /// `self` at `alpha` composited over `base`, as an opaque sRGB color.
    ///
    /// The selected row's text is chosen against the color it actually sits on:
    /// the translucent highlight fill *blended over the card background*, not the
    /// raw highlight — at 25% opacity the background dominates and inverting the
    /// text on the unblended highlight would pick the wrong shade.
    func composited(alpha: CGFloat, over base: NSColor) -> NSColor {
        guard let top = usingColorSpace(.sRGB),
              let bottom = base.usingColorSpace(.sRGB) else { return self }
        let a = min(max(alpha, 0), 1)
        return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                       green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                       blue: top.blueComponent * a + bottom.blueComponent * (1 - a),
                       alpha: 1)
    }
}

// MARK: - SwiftUI Color bridging

extension Color {
    /// Creates a `Color` from a `#RRGGBB[AA]` (or `#RGB[A]` shorthand) string,
    /// falling back to clear.
    init(hexString: String) {
        self = Color(nsColor: NSColor(hex: hexString) ?? .clear)
    }

    /// The hex string for this color (best-effort via `NSColor`).
    var hexString: String {
        NSColor(self).hexString
    }

    /// A legible foreground (near-black or near-white) for text drawn on top of
    /// `color`, chosen from its perceived luminance. Same rule as TopDrawer's
    /// `Color.readableForeground` so the family's tabs, tiles and rows agree.
    static func readableForeground(on color: NSColor) -> Color {
        let c = color.usingColorSpace(.sRGB) ?? .white
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.62 ? Color.black.opacity(0.82) : .white
    }
}
