import Foundation

/// An 8-bit-per-channel sRGB colour and the `#RRGGBB[AA]` text form Jetty persists it
/// in. Pure arithmetic over bytes and characters, with no colour framework behind it,
/// so the parsing and formatting rules — which are a **storage format**, read by every
/// build on every platform — are unit-testable anywhere.
///
/// `NSColor` keeps the conversions to and from a live colour (see `ColorHex.swift`);
/// this type owns what the string means. Split out in `docs/linux-port-plan.md` §JP-04.
struct RGBA8: Equatable {

    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Rounds unit-interval components to bytes, clamping first.
    ///
    /// The clamp is load-bearing (H19): an extended-range or wide-gamut colour can
    /// report components outside 0...1 even after conversion to sRGB, and formatting
    /// one of those unclamped produces a string that no longer parses — which used to
    /// turn a colour silently into `.clear` on the next read.
    init(clampingRed r: Double, green g: Double, blue b: Double, alpha a: Double) {
        func channel(_ v: Double) -> UInt8 {
            // NaN first, and NaN only. Every comparison against it is false, so it
            // survives both `max` and `min` unchanged and then traps in the `UInt8`
            // conversion — the one input class this clamp did not actually clamp.
            // ±infinity needs no special case and must not get one: `max(-inf, 0)` is
            // 0 and `min(+inf, 1)` is 1, so the clamp already maps them to black and
            // white, which is the right answer. Sending them to 0 alongside NaN would
            // turn a blown-out white into black.
            guard !v.isNaN else { return 0 }
            return UInt8((Swift.min(Swift.max(v, 0), 1) * 255).rounded())
        }
        self.init(red: channel(r), green: channel(g), blue: channel(b), alpha: channel(a))
    }

    /// Parses `#RRGGBB`, `#RRGGBBAA`, or the CSS shorthands `#RGB`/`#RGBA`
    /// (the leading `#` is optional).
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }

        // `UInt64(_, radix:)` accepts a leading "+", so "+ABCDE" would otherwise
        // slip through as a 5-digit value and decode as the wrong color — require
        // pure hex digits before parsing (FAB-B15).
        guard !string.isEmpty, string.allSatisfy(\.isHexDigit) else { return nil }

        // Expand CSS shorthand by doubling each nibble: #abc → #aabbcc (L10).
        if string.count == 3 || string.count == 4 {
            string = string.map { "\($0)\($0)" }.joined()
        }

        guard let value = UInt64(string, radix: 16) else { return nil }

        switch string.count {
        case 6:
            self.init(red: UInt8((value & 0xFF0000) >> 16),
                      green: UInt8((value & 0x00FF00) >> 8),
                      blue: UInt8(value & 0x0000FF),
                      alpha: 255)
        case 8:
            self.init(red: UInt8((value & 0xFF00_0000) >> 24),
                      green: UInt8((value & 0x00FF_0000) >> 16),
                      blue: UInt8((value & 0x0000_FF00) >> 8),
                      alpha: UInt8(value & 0x0000_00FF))
        default:
            return nil
        }
    }

    /// `#RRGGBB` (fully opaque) or `#RRGGBBAA` (translucent) — emitting alpha only
    /// when present keeps existing opaque presets byte-identical while letting
    /// translucent colors round-trip (L9).
    var hexString: String {
        alpha < 255 ? String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
                    : String(format: "#%02X%02X%02X", red, green, blue)
    }
}
