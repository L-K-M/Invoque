import XCTest
@testable import Invoque

final class CommandRunnerTests: XCTestCase {

    private var directory: URL!
    private let runner = CommandRunner()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testRunReturnsResult() async throws {
        let command = try makeCommand(source: """
            async function run() { return { title: "done" }; }
            """)
        let result = await runner.run(command: command)
        XCTAssertEqual(result.title, "done")
    }

    func testQueryPassesTextAsFirstArg() async throws {
        let command = try makeCommand(mode: "filter", source: """
            async function run(args) {
                return { items: [{ title: "item for " + args[0] }] };
            }
            """)
        let items = try await runner.query(command: command, text: "abc")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "item for abc")
    }

    func testQueryThrowsOnScriptFailure() async throws {
        let command = try makeCommand(mode: "filter", source: """
            async function run() { throw new Error("nope"); }
            """)
        do {
            _ = try await runner.query(command: command, text: "x")
            XCTFail("expected query to throw")
        } catch is JSResult.Failure {
            // Expected — a script failure propagates as JSResult.Failure.
        }
    }

    // MARK: Helpers

    private func makeCommand(name: String = "test-command",
                             mode: String = "action",
                             permissions: [String] = [],
                             source: String) throws -> Command {
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "name": name,
            "title": name,
            "runtime": "js",
            "entry": "main.js",
            "mode": mode,
            "permissions": permissions,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("command.json"))
        try source.write(to: directory.appendingPathComponent("main.js"),
                         atomically: true, encoding: .utf8)
        return try Command(directory: directory)
    }
}
