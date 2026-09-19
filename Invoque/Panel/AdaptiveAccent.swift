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

    /// Locked rather than main-confined: today only `PanelView` calls this
    /// (from `body`, on main), but nothing in the API contract requires it —
    /// a future background prefetch must not race the read-modify-write.
    private static let cacheLock = NSLock()
    /// Misses are cached too (`NSColor?`), so an icon that can't be sampled
    /// isn't re-rasterized on every selection change.
    private static var cache: [String: NSColor?] = [:]

    /// The accent for the image the row actually draws — the shared-store
    /// resolution when Pict has one, else the workspace icon — keyed by the
    /// icon's `backingPath`. A Pict override therefore picks up its own
    /// accent, and `invalidate()` (called when the store changes) is what
    /// lets a *changed* icon re-sample rather than returning the old
    /// artwork's color forever.
    static func color(for image: NSImage?, key: String?) -> NSColor? {
        guard let image, let key else { return nil }
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached { return cached }

        let color = image.dominantAccentColor()
        cacheLock.lock()
        cache[key] = color
        cacheLock.unlock()
        return color
    }

    /// Drops every cached accent — the samples were taken from icons that
    /// may no longer be drawn. Called when the shared store reports a
    /// change; the next selection recomputes.
    static func invalidate() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }
}

// Internal (not private) so the premultiplied-alpha handling is unit-testable.
extension NSImage {
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

        // CoreImage works in premultiplied alpha; depending on the render path
        // the RGBA8 bitmap may hold premultiplied channels, which would drag a
        // translucent icon's average toward black. A channel above alpha can't
        // exist in premultiplied data — that detects straight output and skips
        // the division, so this is correct under either layout.
        let alpha = CGFloat(pixel[3]) / 255
        let isPremultiplied = alpha >= 1
            || (pixel[0...2].allSatisfy { CGFloat($0) / 255 <= alpha })
        func channel(_ v: UInt8) -> CGFloat {
            let c = CGFloat(v) / 255
            guard isPremultiplied, alpha > 0 else { return c }
            return min(c / alpha, 1)
        }
        let base = NSColor(red: channel(pixel[0]), green: channel(pixel[1]),
                           blue: channel(pixel[2]), alpha: 1)
        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.5, 1), brightness: max(b, 0.65), alpha: a)
    }
}
