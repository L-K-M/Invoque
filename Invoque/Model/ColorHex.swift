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

    /// `self` at the additional `alpha` composited over an opaque `base` estimate.
    ///
    /// The selected row's text is chosen against the color it actually sits on:
    /// the translucent highlight fill *blended over the card background*, not the
    /// raw highlight — at 25% opacity the background dominates and inverting the
    /// text on the unblended highlight would pick the wrong shade.
    func composited(alpha: CGFloat, over base: NSColor) -> NSColor {
        guard let top = usingColorSpace(.sRGB),
              let bottom = base.usingColorSpace(.sRGB) else { return self }
        // SwiftUI's opacity multiplies the imported color's own alpha. Ignoring
        // that alpha can choose dark text for a clear highlight on a dark card.
        let a = min(max(alpha, 0), 1) * top.alphaComponent
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

    /// Whichever opaque foreground has greater contrast against the estimated
    /// background. Linearized sRGB luminance keeps saturated colors such as
    /// green from incorrectly choosing white text. Formula: WCAG 2.2, SC 1.4.3.
    static func readableForeground(on color: NSColor) -> Color {
        let c = color.usingColorSpace(.sRGB) ?? .white
        func linearized(_ channel: CGFloat) -> CGFloat {
            let value = min(max(channel, 0), 1)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearized(c.redComponent)
            + 0.7152 * linearized(c.greenComponent)
            + 0.0722 * linearized(c.blueComponent)
        let contrastWithBlack = (luminance + 0.05) / 0.05
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        return contrastWithBlack >= contrastWithWhite ? .black : .white
    }
}
