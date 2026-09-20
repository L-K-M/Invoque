import XCTest
@testable import Invoque

final class StatusIconTests: XCTestCase {

    /// The menu-bar icon only reaches the built app through the generated
    /// `StatusIcon.imageset` — a rename, a membership slip, or an actool
    /// failure would degrade `statusBarImage()` to the generic SF Symbol
    /// fallback with no other signal. `--verify` guards the files on disk;
    /// this guards the catalog actually resolving in the bundle.
    func testStatusIconAssetResolvesFromAppBundle() {
        XCTAssertNotNil(
            Bundle(for: AppDelegate.self)
                .image(forResource: NSImage.Name("StatusIcon")),
            "StatusIcon.imageset did not resolve — statusBarImage() would "
                + "silently fall back to an SF Symbol")
    }
}
