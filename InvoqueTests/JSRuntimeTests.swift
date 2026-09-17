import XCTest
@testable import Invoque

final class JSRuntimeTests: XCTestCase {

    private var directory: URL!
    private let runtime = JSRuntime()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-js-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: Entry contract

    func testAsyncFunctionRunReturnsTitle() async throws {
        let command = try makeCommand(source: """
            async function run(args) {
                return { title: "hi " + args[0] };
            }
            """)
        let result = try await runtime.run(command: command, args: ["x"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "hi x")
    }

    func testExportDefaultStyle() async throws {
        let command = try makeCommand(source: """
            export default async function (args) {
                return { title: "hi " + args[0] };
            }
            """)
        let result = try await runtime.run(command: command, args: ["x"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "hi x")
    }

    func testThrowingScriptSurfacesError() async throws {
        let command = try makeCommand(source: """
            async function run() { throw new Error("boom"); }
            """)
        let result = try await runtime.run(command: command)
        guard case .rejected(let message)? = result.error else {
            XCTFail("expected .rejected, got \(String(describing: result.error))")
            return
        }
        XCTAssertTrue(message.contains("boom"))
    }

    func testSynchronousThrowSurfacesError() async throws {
        let command = try makeCommand(source: """
            function run() { throw new Error("sync boom"); }
            """)
        let result = try await runtime.run(command: command)
        guard case .exception(let message)? = result.error else {
            XCTFail("expected .exception, got \(String(describing: result.error))")
            return
        }
        XCTAssertTrue(message.contains("sync boom"))
    }

    func testMissingEntryPoint() async throws {
        let command = try makeCommand(source: """
            const x = 1;
            """)
        let result = try await runtime.run(command: command)
        XCTAssertEqual(result.error, .missingEntryPoint)
    }

    // MARK: Permission gating

    func testFetchAbsentWithoutNetworkPermission() async throws {
        let command = try makeCommand(source: """
            async function run() { return { title: typeof invoque.fetch }; }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "undefined")
    }

    func testFetchPresentWithNetworkPermission() async throws {
        let command = try makeCommand(permissions: ["network"], source: """
            async function run() { return { title: typeof invoque.fetch }; }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "function")
    }

    func testShellAbsentInFilterMode() async throws {
        let command = try makeCommand(mode: "filter", permissions: ["shell"], source: """
            async function run() { return { title: typeof invoque.shell }; }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "undefined")
    }

    func testShellPresentInActionMode() async throws {
        let command = try makeCommand(permissions: ["shell"], source: """
            async function run() { return { title: typeof invoque.shell }; }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "object")
    }

    // MARK: Storage

    func testStoragePersistsAcrossRuns() async throws {
        let command = try makeCommand(source: """
            async function run() {
                invoque.storage.set("key", "value");
                return { title: "stored" };
            }
            """)
        let first = try await runtime.run(command: command)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.title, "stored")

        let storageFile = directory.appendingPathComponent("data/storage.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageFile.path))

        // Same command, fresh context — the value must come from disk.
        try """
        async function run() { return { title: invoque.storage.get("key") }; }
        """.write(to: command.entryURL, atomically: true, encoding: .utf8)
        let second = try await runtime.run(command: command)
        XCTAssertNil(second.error)
        XCTAssertEqual(second.title, "value")
    }

    // MARK: Result decoding

    func testItemsDecode() async throws {
        let command = try makeCommand(source: """
            async function run() {
                return { items: [{ title: "a" }] };
            }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.items?.count, 1)
        XCTAssertEqual(result.items?.first?.title, "a")
    }

    func testVoidResult() async throws {
        let command = try makeCommand(source: """
            async function run() { }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, .void)
    }

    func testConsoleLogCaptured() async throws {
        let command = try makeCommand(source: """
            async function run() {
                console.log("hello", "world");
                return { title: "done" };
            }
            """)
        let result = try await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.logs.contains { $0.contains("hello world") })
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
