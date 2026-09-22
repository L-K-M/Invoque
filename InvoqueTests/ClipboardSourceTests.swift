import XCTest
@testable import Invoque

final class ClipboardSourceTests: XCTestCase {

    // MARK: Keyword routing

    /// The first word must be exactly `clip` or `paste` — a prefix match
    /// would also route unrelated queries like "clippers" here.
    func testClipboardKeywordRouting() {
        XCTAssertTrue(ClipboardSource.isClipboardQuery("clip"))
        XCTAssertTrue(ClipboardSource.isClipboardQuery("paste"))
        XCTAssertTrue(ClipboardSource.isClipboardQuery("CLIP"))
        XCTAssertTrue(ClipboardSource.isClipboardQuery("  paste   "))
        XCTAssertTrue(ClipboardSource.isClipboardQuery("clip token"))

        XCTAssertFalse(ClipboardSource.isClipboardQuery("clippers"))
        XCTAssertFalse(ClipboardSource.isClipboardQuery("pastedown"))
        XCTAssertFalse(ClipboardSource.isClipboardQuery("clipboard"))
        XCTAssertFalse(ClipboardSource.isClipboardQuery("the clip"))
        XCTAssertFalse(ClipboardSource.isClipboardQuery(""))
    }
}
