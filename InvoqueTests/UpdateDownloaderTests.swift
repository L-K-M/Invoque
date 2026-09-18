import XCTest
@testable import Invoque

final class UpdateDownloaderTests: XCTestCase {

    func testUniqueDestinationAvoidsCollisions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("UpdateDownloaderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque.dmg", fileManager: fm)
        XCTAssertEqual(first.lastPathComponent, "Invoque.dmg")
        XCTAssertEqual(first.deletingLastPathComponent(), dir,
                       "the destination must resolve inside the target directory")
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque.dmg", fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "Invoque-1.dmg")
        XCTAssertEqual(second.deletingLastPathComponent(), dir)
        XCTAssertTrue(fm.createFile(atPath: second.path, contents: Data()))

        let third = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque.dmg", fileManager: fm)
        XCTAssertEqual(third.lastPathComponent, "Invoque-2.dmg")
        XCTAssertEqual(third.deletingLastPathComponent(), dir)
    }

    /// Remote asset names are untrusted: traversal and subdirectories must be
    /// stripped to a single component inside Downloads.
    func testSafeFileNameStripsTraversal() {
        XCTAssertEqual(UpdateDownloader.safeFileName("../../evil.sh"), "evil.sh")
        XCTAssertEqual(UpdateDownloader.safeFileName("sub/dir/App.dmg"), "App.dmg")
        XCTAssertEqual(UpdateDownloader.safeFileName(".."), "download")
        XCTAssertEqual(UpdateDownloader.safeFileName("."), "download")
        XCTAssertEqual(UpdateDownloader.safeFileName("/"), "download")
        XCTAssertEqual(UpdateDownloader.safeFileName("//"), "download")
        XCTAssertEqual(UpdateDownloader.safeFileName(""), "download")
        XCTAssertEqual(UpdateDownloader.safeFileName("App.dmg"), "App.dmg")
    }

    func testUniqueDestinationHandlesNameWithoutExtension() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("UpdateDownloaderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque", fileManager: fm)
        XCTAssertEqual(first.lastPathComponent, "Invoque")
        XCTAssertEqual(first.deletingLastPathComponent(), dir)
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque", fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "Invoque-1")
        XCTAssertEqual(second.deletingLastPathComponent(), dir)
    }

    /// The production path composes the two helpers — a sanitized traversal
    /// name must still land inside the target directory.
    func testComposedSafeFileNameStaysContained() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("UpdateDownloaderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let dest = UpdateDownloader.uniqueDestination(
            in: dir, fileName: UpdateDownloader.safeFileName("../../evil.sh"),
            fileManager: fm)
        XCTAssertEqual(dest.deletingLastPathComponent(), dir)
        XCTAssertEqual(dest.lastPathComponent, "evil.sh")
    }
}
