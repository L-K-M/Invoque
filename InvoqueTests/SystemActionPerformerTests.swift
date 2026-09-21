import XCTest
@testable import Invoque

/// Covers `emptyTrashContents`, the testable half of Empty Trash: the
/// HUD text and the queue hop live in the untestable shell around it.
final class SystemActionPerformerTests: XCTestCase {

    private var trash: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore write permission in case a test revoked it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: trash.path)
        try? FileManager.default.removeItem(at: trash)
        trash = nil
        try super.tearDownWithError()
    }

    /// Every entry disappears and the failure count is zero.
    func testEmptyTrashContentsRemovesAllEntries() throws {
        try "a".write(to: trash.appendingPathComponent("a.txt"),
                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: trash.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: false)
        try "b".write(to: trash.appendingPathComponent("folder/b.txt"),
                      atomically: true, encoding: .utf8)

        XCTAssertEqual(SystemActionPerformer.emptyTrashContents(at: trash), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    /// An unreadable directory reports nil — the shell maps that to the
    /// "couldn't read" HUD rather than a miscount.
    func testEmptyTrashContentsReturnsNilForMissingDirectory() {
        let gone = trash.appendingPathComponent("no-such-dir", isDirectory: true)
        XCTAssertNil(SystemActionPerformer.emptyTrashContents(at: gone))
    }

    /// A read-only Trash keeps its entries — removal needs write on the
    /// parent — and the failures come back counted, not silently dropped.
    func testEmptyTrashContentsCountsUnremovableEntries() throws {
        try XCTSkipIf(geteuid() == 0, "Root ignores directory permissions")
        try "a".write(to: trash.appendingPathComponent("a.txt"),
                      atomically: true, encoding: .utf8)
        try "b".write(to: trash.appendingPathComponent("b.txt"),
                      atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: trash.path)

        XCTAssertEqual(SystemActionPerformer.emptyTrashContents(at: trash), 2)

        // Prove the files are still there — "left behind" is the contract.
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: trash.path)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 2)
    }

    /// A dangling symlink that can't be removed still counts — the
    /// vanished-entry check must key on the removal error, not a
    /// fileExists probe that would follow the dead link to nowhere.
    func testEmptyTrashContentsCountsUndeadSymlink() throws {
        try XCTSkipIf(geteuid() == 0, "Root ignores directory permissions")
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("dangling"),
            withDestinationURL: trash.appendingPathComponent("gone"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: trash.path)

        XCTAssertEqual(SystemActionPerformer.emptyTrashContents(at: trash), 1)
    }
}
