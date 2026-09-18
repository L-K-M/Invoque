import AppKit
import CoreImage

/// The selected row's accent when **adaptive accent** is on: the row's icon
/// average color, saturation-boosted so it reads as an accent rather than mud,
/// and cached by icon identity (icons are stable, so the sample is computed
/// once). Invoque's counterpart to Jetty's `TileAccent` — where that glows on a
/// hovered tile, this tints the launcher's selection: Safari rows glow
/// orange-ish, Terminal dark, Notes yellow.
///
/// `.symbol` rows have no bitmap to sample and return `nil` — the caller falls
/// back to the theme's configured highlight color.
enum AdaptiveAccent {

    private static var cache: [String: NSColor] = [:]

    static func color(for icon: Item.Icon) -> NSColor? {
        switch icon {
        case .symbol:
            return nil
        case .fileURL(let url):
            return dominantColor(forFileAt: url.path)
        case .appIcon(let path):
            return dominantColor(forFileAt: path)
        }
    }

    private static func dominantColor(forFileAt path: String) -> NSColor? {
        if let cached = cache[path] { return cached }
        guard let color = NSWorkspace.shared.icon(forFile: path).dominantAccentColor()
        else { return nil }
        cache[path] = color
        return color
    }
}

private extension NSImage {
    /// One shared `CIContext` for all dominant-color sampling. `CIContext` is
    /// documented as expensive to build (it wires up a full render pipeline), so
    /// it is allocated once rather than per call.
    static let accentContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// The image's average color, pushed toward a vivid accent. `nil` if it
    /// can't be rasterized (e.g. an empty image).
    func dominantAccentColor() -> NSColor? {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci,
                                                 kCIInputExtentKey: CIVector(cgRect: extent)]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        Self.accentContext.render(output, toBitmap: &pixel, rowBytes: 4,
                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: .RGBA8, colorSpace: nil)

        let base = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255, alpha: 1)
        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.5, 1), brightness: max(b, 0.65), alpha: a)
    }
}
