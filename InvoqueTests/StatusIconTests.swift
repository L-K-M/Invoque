import AppKit
import XCTest
@testable import Invoque

final class StatusIconTests: XCTestCase {

    /// The menu-bar icon only reaches the built app through the generated
    /// `StatusIcon.imageset` — a rename, a membership slip, or an actool
    /// failure would degrade `statusBarImage()` to the generic SF Symbol
    /// fallback with no other signal. `--verify` guards the files on disk;
    /// this guards the catalog actually resolving in the bundle — and
    /// resolving non-template, so the mark draws in color rather than as a
    /// tinted silhouette.
    func testStatusIconAssetResolvesFromAppBundle() throws {
        let image = try XCTUnwrap(
            Bundle(for: AppDelegate.self)
                .image(forResource: NSImage.Name("StatusIcon")),
            "StatusIcon.imageset did not resolve — statusBarImage() would "
                + "silently fall back to an SF Symbol")
        XCTAssertFalse(image.isTemplate,
                       "the mark must draw in color — template rendering "
                           + "would flatten it to a silhouette")
    }
}
