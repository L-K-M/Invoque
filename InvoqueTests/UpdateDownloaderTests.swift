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
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque.dmg", fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "Invoque-1.dmg")
        XCTAssertTrue(fm.createFile(atPath: second.path, contents: Data()))

        let third = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque.dmg", fileManager: fm)
        XCTAssertEqual(third.lastPathComponent, "Invoque-2.dmg")
    }

    /// Remote asset names are untrusted: traversal and subdirectories must be
    /// stripped to a single component inside Downloads.
    func testSafeFileNameStripsTraversal() {
        XCTAssertEqual(UpdateDownloader.safeFileName("../../evil.sh"), "evil.sh")
        XCTAssertEqual(UpdateDownloader.safeFileName("sub/dir/App.dmg"), "App.dmg")
        XCTAssertEqual(UpdateDownloader.safeFileName(".."), "download")
        XCTAssertEqual(UpdateDownloader.safeFileName("."), "download")
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
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = UpdateDownloader.uniqueDestination(in: dir, fileName: "Invoque", fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "Invoque-1")
    }
}
