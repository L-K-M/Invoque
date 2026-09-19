import AppKit
import Combine
import XCTest
import PictKit
@testable import Invoque

/// The `Item.Icon` → `IconTarget` mapping — the seam that decides which
/// rungs of the shared-store ladder each row kind gets.
final class InvoqueIconsTests: XCTestCase {

    /// An app row resolves as `.application` with both rungs: the bundle
    /// path first, the identifier second — so a Pict override keyed either
    /// way applies, and an SSB wrapper's borrowed identifier can't paint
    /// every wrapper the same.
    func testAppIconMapsToApplicationTarget() {
        let target = Item.Icon
            .appIcon(path: "/Applications/Safari.app", bundleID: "com.apple.Safari")
            .pictTarget
        XCTAssertEqual(target,
                       .application(bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                                    bundleIdentifier: "com.apple.Safari"))
    }

    /// An app row with no known identifier keeps the path rung only.
    func testAppIconWithoutBundleIDMapsPathOnly() {
        let target = Item.Icon
            .appIcon(path: "/Applications/Foo.app", bundleID: nil)
            .pictTarget
        XCTAssertEqual(target,
                       .application(bundleURL: URL(fileURLWithPath: "/Applications/Foo.app"),
                                    bundleIdentifier: nil))
    }

    /// A file row is a `.file` target — a user-set icon for that exact
    /// path applies; anything else resolves to the system icon.
    func testFileURLMapsToFileTarget() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        XCTAssertEqual(Item.Icon.fileURL(url).pictTarget, .file(url))
    }

    /// SF Symbols name no thing on disk — nothing to resolve.
    func testSymbolHasNoTarget() {
        XCTAssertNil(Item.Icon.symbol("terminal").pictTarget)
        XCTAssertNil(Item.Icon.symbol("terminal").backingPath)
    }

    /// `backingPath` is the workspace-icon fallback and the accent key.
    func testBackingPaths() {
        XCTAssertEqual(Item.Icon.fileURL(URL(fileURLWithPath: "/tmp/x")).backingPath,
                       "/tmp/x")
        XCTAssertEqual(Item.Icon.appIcon(path: "/Applications/Foo.app",
                                         bundleID: "com.foo").backingPath,
                       "/Applications/Foo.app")
    }

    /// The invalidation hook republishes — the view must learn that its
    /// icons stopped being the right ones so rows redraw. (It also drops
    /// the accent cache; `AdaptiveAccent.invalidate` is covered by its
    /// own suite's sampling tests.)
    func testNoteIconsChangedRepublishes() {
        let model = PanelModel()
        var fired = 0
        let subscription = model.objectWillChange.sink { _ in fired += 1 }
        model.noteIconsChanged()
        XCTAssertGreaterThanOrEqual(fired, 1)
        subscription.cancel()
    }

    /// Accent sampling takes the drawn image — nothing to sample, no
    /// accent, whatever the key says.
    func testAccentRequiresImageAndKey() {
        XCTAssertNil(AdaptiveAccent.color(for: nil, key: "/tmp/x"))
        XCTAssertNil(AdaptiveAccent.color(for: NSImage(), key: nil))
    }
}
