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
        let result = await runtime.run(command: command, args: ["x"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "hi x")
    }

    func testExportDefaultStyle() async throws {
        let command = try makeCommand(source: """
            export default async function (args) {
                return { title: "hi " + args[0] };
            }
            """)
        let result = await runtime.run(command: command, args: ["x"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "hi x")
    }

    func testThrowingScriptSurfacesError() async throws {
        let command = try makeCommand(source: """
            async function run() { throw new Error("boom"); }
            """)
        let result = await runtime.run(command: command)
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
        let result = await runtime.run(command: command)
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
        let result = await runtime.run(command: command)
        XCTAssertEqual(result.error, .missingEntryPoint)
    }

    func testPromiseRejectionSurfacesError() async throws {
        let command = try makeCommand(source: """
            async function run() { return Promise.reject(new Error("nope")); }
            """)
        let result = await runtime.run(command: command)
        guard case .rejected(let message)? = result.error else {
            XCTFail("expected .rejected, got \(String(describing: result.error))")
            return
        }
        XCTAssertTrue(message.contains("nope"))
    }

    func testNonErrorThrowSurfacesError() async throws {
        // A thrown object JSON-stringifies — not "[object Object]".
        let command = try makeCommand(source: """
            async function run() { throw { code: 42 }; }
            """)
        let result = await runtime.run(command: command)
        guard case .rejected(let message)? = result.error else {
            XCTFail("expected .rejected, got \(String(describing: result.error))")
            return
        }
        XCTAssertTrue(message.contains("42"))
    }

    func testThrownStringSurfacesVerbatim() async throws {
        let command = try makeCommand(source: """
            async function run() { throw "plain string boom"; }
            """)
        let result = await runtime.run(command: command)
        guard case .rejected(let message)? = result.error else {
            XCTFail("expected .rejected, got \(String(describing: result.error))")
            return
        }
        XCTAssertEqual(message, "plain string boom")
    }

    func testInfiniteLoopTimesOutAndCommandIsRefused() async throws {
        let command = try makeCommand(source: """
            function run() { while (true) {} }
            """)
        let result = await runtime.run(command: command, timeout: 0.5)
        XCTAssertEqual(result.error, .timedOut)

        // A stuck script never releases its queue/context — the runtime
        // must refuse to strand another one rather than run it again, and
        // must say so instead of looking like a fresh timeout.
        let second = await runtime.run(command: command, timeout: 30)
        XCTAssertEqual(second.error, .timedOut)
        XCTAssertTrue(second.logs.contains { $0.contains("disabled for the rest of the session") })
    }

    func testParkedPromiseTimeoutDoesNotBanCommand() async throws {
        // A script that returns a never-resolving promise is parked, not
        // wedged: its queue thread is free, so the timeout must not get the
        // command banned for the session.
        let command = try makeCommand(source: """
            function run() { return new Promise(function () {}); }
            """)
        let result = await runtime.run(command: command, timeout: 0.5)
        XCTAssertEqual(result.error, .timedOut)

        try "function run() { return { title: \"healthy\" }; }".write(
            to: command.entryURL, atomically: true, encoding: .utf8)
        let second = await runtime.run(command: command)
        XCTAssertNil(second.error)
        XCTAssertEqual(second.title, "healthy")
    }

    func testUnreadableEntrySurfacesException() async throws {
        // Root reads through permission bits — the test only works for an
        // unprivileged process.
        try XCTSkipIf(getuid() == 0, "chmod-based unreadable file is readable as root")
        let command = try makeCommand(source: """
            async function run() { return { title: "x" }; }
            """)
        // Permissions drop below the read — file still exists (validation
        // already passed) but is no longer readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: command.entryURL.path)
        let result = await runtime.run(command: command)
        guard case .exception(let message)? = result.error else {
            XCTFail("expected .exception, got \(String(describing: result.error))")
            return
        }
        XCTAssertTrue(message.contains("could not read entry file"))
    }

    // MARK: Permission gating

    func testFetchAbsentWithoutNetworkPermission() async throws {
        let command = try makeCommand(source: """
            async function run() { return { title: typeof invoque.fetch }; }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "undefined")
    }

    func testFetchPresentWithNetworkPermission() async throws {
        let command = try makeCommand(permissions: ["network"], source: """
            async function run() { return { title: typeof invoque.fetch }; }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "function")
    }

    func testShellAbsentInFilterMode() async throws {
        let command = try makeCommand(mode: "filter", permissions: ["shell"], source: """
            async function run() { return { title: typeof invoque.shell }; }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "undefined")
    }

    func testShellPresentInActionMode() async throws {
        let command = try makeCommand(permissions: ["shell"], source: """
            async function run() { return { title: typeof invoque.shell }; }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "object")
    }

    func testPasteAbsentInFilterMode() async throws {
        let command = try makeCommand(mode: "filter", permissions: ["paste"], source: """
            async function run() { return { title: typeof invoque.paste }; }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "undefined")
    }

    func testFetchRejectsFileScheme() async throws {
        // `network` must not become arbitrary filesystem access.
        let command = try makeCommand(permissions: ["network"], source: """
            async function run() {
                try {
                    await invoque.fetch("file:///etc/passwd");
                    return { title: "resolved" };
                } catch (e) {
                    return { title: "rejected" };
                }
            }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "rejected")
    }

    func testOpenRejectsNonWebTargets() async throws {
        // Always-on and permission-free, so it only opens http(s) — local
        // paths and file: URLs return false rather than launching.
        let command = try makeCommand(source: """
            async function run() {
                return { title: String(invoque.open("file:///etc/passwd"))
                         + "|" + String(invoque.open("/Applications/Safari.app")) };
            }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "false|false")
    }

    // MARK: Storage

    func testStoragePersistsAcrossRuns() async throws {
        let command = try makeCommand(source: """
            async function run() {
                invoque.storage.set("key", "value");
                return { title: "stored" };
            }
            """)
        let first = await runtime.run(command: command)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.title, "stored")

        let storageFile = directory.appendingPathComponent("data/storage.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageFile.path))

        // Same command, fresh context AND fresh runtime — the value must
        // come from disk, not a runtime-held cache.
        try """
        async function run() { return { title: invoque.storage.get("key") }; }
        """.write(to: command.entryURL, atomically: true, encoding: .utf8)
        let second = await JSRuntime().run(command: command)
        XCTAssertNil(second.error)
        XCTAssertEqual(second.title, "value")
    }

    func testConcurrentStorageWritesKeepBothKeys() async throws {
        // Two invocations writing different keys at once: whichever commits
        // second must merge, not overwrite the other's key.
        let command = try makeCommand(source: """
            async function run(args) {
                invoque.storage.set(args[0], args[1]);
                return { title: "ok" };
            }
            """)
        async let a = runtime.run(command: command, args: ["k1", "v1"])
        async let b = runtime.run(command: command, args: ["k2", "v2"])
        let (resultA, resultB) = await (a, b)
        XCTAssertNil(resultA.error)
        XCTAssertNil(resultB.error)

        let data = try Data(contentsOf: directory.appendingPathComponent("data/storage.json"))
        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(stored["k1"], "v1")
        XCTAssertEqual(stored["k2"], "v2")
    }

    // MARK: Result decoding

    func testItemsDecode() async throws {
        let command = try makeCommand(source: """
            async function run() {
                return { items: [{ title: "a" }] };
            }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.items?.count, 1)
        XCTAssertEqual(result.items?.first?.title, "a")
    }

    func testVoidResult() async throws {
        let command = try makeCommand(source: """
            async function run() { }
            """)
        let result = await runtime.run(command: command)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, .void)
    }

    func testPrimitiveAndNullReturnsDecodeAsVoid() async throws {
        // A bare number or null is not a title — only {title}/{items}
        // objects carry output. makeCommand rewrites the same directory,
        // so each variant runs before the next is written.
        let number = try makeCommand(source: """
            async function run() { return 42; }
            """)
        let numberResult = await runtime.run(command: number)
        XCTAssertNil(numberResult.error)
        XCTAssertEqual(numberResult.output, .void)

        let null_ = try makeCommand(source: """
            async function run() { return null; }
            """)
        let nullResult = await runtime.run(command: null_)
        XCTAssertNil(nullResult.error)
        XCTAssertEqual(nullResult.output, .void)
    }

    // MARK: Source transform

    func testPreprocessRewritesEntryForms() {
        XCTAssertEqual(
            JSRuntime.preprocess("export default async function run() {}"),
            "globalThis.run = async function run() {}")
        XCTAssertEqual(
            JSRuntime.preprocess("export default function run() {}"),
            "globalThis.run = function run() {}")
        XCTAssertEqual(
            JSRuntime.preprocess("export default (args) => args"),
            "globalThis.run = (args) => args")
    }

    func testPreprocessLeavesStringLiteralAlone() {
        // The token inside the string is not followed by a callable, so the
        // real declaration later in the file is the one rewritten.
        let source = #"const s = "export default"; export default function run() {}"#
        XCTAssertEqual(
            JSRuntime.preprocess(source),
            #"const s = "export default"; globalThis.run = function run() {}"#)
    }

    func testPreprocessSkipsCallableFormInsideLiteral() {
        // `export default function` inside a string must stay a string —
        // rewriting it would corrupt the literal's contents.
        let source = #"const s = "export default function() {}";"#
        XCTAssertEqual(JSRuntime.preprocess(source), source)
        let template = #"const s = `export default function() {}`;"#
        XCTAssertEqual(JSRuntime.preprocess(template), template)
    }

    func testPreprocessSkipsCallableFormInsideComment() {
        // A comment ahead of the real export must not consume the rewrite —
        // the real declaration is still the one rewritten.
        let source = "// export default function() {}\nexport default function run() {}"
        XCTAssertEqual(
            JSRuntime.preprocess(source),
            "// export default function() {}\nglobalThis.run = function run() {}")
        let block = "/* export default function() {} */\nexport default function run() {}"
        XCTAssertEqual(
            JSRuntime.preprocess(block),
            "/* export default function() {} */\nglobalThis.run = function run() {}")
    }

    // MARK: Shell

    func testShellRunDoesNotHangOnBackgroundedChild() async throws {
        // A backgrounded grandchild inherits our stdout pipe; without a
        // bound on the drain, readDataToEndOfFile would outlive the shell.
        let command = try makeCommand(permissions: ["shell"], source: """
            async function run() {
                const r = invoque.shell.run("sleep 30 & echo done");
                return { title: r.stdout.trim() + ":" + r.code };
            }
            """)
        let result = await runtime.run(command: command, timeout: 15)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.title, "done:0")
    }

    func testConsoleLogCaptured() async throws {
        let command = try makeCommand(source: """
            async function run() {
                console.log("hello", "world");
                return { title: "done" };
            }
            """)
        let result = await runtime.run(command: command)
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
