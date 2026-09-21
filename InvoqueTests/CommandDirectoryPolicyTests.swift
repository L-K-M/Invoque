import XCTest
@testable import Invoque

/// Direct coverage for `CommandDirectoryPolicy.validateWriteDestinations` —
/// the load-path tests exercise only `validatedDataDirectory`/`StorageURL`.
final class CommandDirectoryPolicyTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
    }

    func testRejectsSymlinkedIntermediateComponent() throws {
        let directory = try makeDirectory()
        let outside = try makeDirectory(prefix: "invoque-outside")
        let sub = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: sub.appendingPathComponent("link"),
            withDestinationURL: outside)

        XCTAssertThrowsError(
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: directory, relativePaths: ["sub/link/target.js"])
        ) { error in
            XCTAssertEqual(error as? CommandDirectoryPolicy.Violation,
                           .symbolicLink("sub/link/target.js"))
        }
    }

    func testRejectsEscapingRelativePath() throws {
        let directory = try makeDirectory()

        XCTAssertThrowsError(
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: directory, relativePaths: ["../escape.js"])
        ) { error in
            XCTAssertEqual(error as? CommandDirectoryPolicy.Violation,
                           .escapesDirectory("../escape.js"))
        }
    }

    /// An empty path resolves to the command directory itself, which is not
    /// a descendant of itself — the rejection is explicit, never a silent
    /// pass that would bless the root as a file destination.
    func testEmptyRelativePathRejectsAsEscape() throws {
        let directory = try makeDirectory()

        XCTAssertThrowsError(
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: directory, relativePaths: [""])
        ) { error in
            XCTAssertEqual(error as? CommandDirectoryPolicy.Violation,
                           .escapesDirectory(""))
        }
    }

    /// A leading slash is just another component here — "/etc/passwd" is
    /// appended as etc/passwd inside the command directory, not read as a
    /// filesystem root.
    func testAbsoluteLookingPathStaysInside() throws {
        let directory = try makeDirectory()

        XCTAssertNoThrow(
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: directory, relativePaths: ["/etc/passwd"]))
    }

    func testNonexistentDestinationPasses() throws {
        let directory = try makeDirectory()

        XCTAssertNoThrow(
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: directory, relativePaths: ["lib/util.js"]))
    }

    func testRejectsSymlinkedCommandRoot() throws {
        let real = try makeDirectory()
        let linkParent = try makeDirectory(prefix: "invoque-parent")
        let link = linkParent.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: real)

        XCTAssertThrowsError(
            try CommandDirectoryPolicy.validateWriteDestinations(
                in: link, relativePaths: ["main.js"])
        ) { error in
            XCTAssertEqual(error as? CommandDirectoryPolicy.Violation,
                           .symbolicLink("."))
        }
    }

    private func makeDirectory(prefix: String = "invoque-policy") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }
}
