import XCTest
@testable import Invoque

final class GeneratedCommandValidatorTests: XCTestCase {

    // MARK: Helpers

    private func manifestJSON(name: String = "demo",
                              mode: String = "action",
                              permissions: [String] = []) -> String {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "schemaVersion": 1, "name": "\(name)", "title": "Demo",
          "runtime": "js", "entry": "main.js", "mode": "\(mode)",
          "permissions": [\(list)]
        }
        """
    }

    private func generation(manifest: String, entry: String,
                            entryName: String = "main.js") -> GeneratedCommand {
        GeneratedCommand(manifestJSON: manifest, entryName: entryName,
                         entrySource: entry, extraFiles: [:])
    }

    // MARK: Happy path

    func testCleanGenerationHasNoIssues() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: """
            export default async function run(args, ctx) {
                return { title: "hi" };
            }
            """))
        XCTAssertEqual(outcome.issues, [])
        XCTAssertEqual(outcome.manifest?.name, "demo")
        XCTAssertTrue(outcome.isValid)
    }

    // MARK: Manifest problems

    func testUndecodableManifestIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: "not json",
            entry: "async function run() {}"))
        XCTAssertNil(outcome.manifest)
        XCTAssertEqual(outcome.issues.count, 1)
        XCTAssertTrue(outcome.issues[0].contains("command.json"))
    }

    func testStructurallyInvalidManifestIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(name: "Bad Name!"),
            entry: "async function run() {}"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("invalid command name") })
    }

    func testManifestEntryMismatchIsAnIssue() {
        // Manifest says index.js but the file emitted is main.js.
        let manifest = manifestJSON().replacingOccurrences(of: "\"main.js\"",
                                                           with: "\"index.js\"")
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifest, entry: "async function run() {}"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("index.js") })
    }

    // MARK: JavaScript

    func testJSSyntaxErrorIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: "async function run( {"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("doesn't parse") })
    }

    /// Compilation must not *run* the code — a top-level side effect (or
    /// infinite loop) can't hang or fire during validation.
    func testJSIsCompiledNotRun() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: """
            while (true) {}
            async function run() {}
            """))
        // If this test returns at all, nothing executed. The compile itself
        // is fine, so no parse issue — but also no entry-point issue (run
        // exists).
        XCTAssertFalse(outcome.issues.contains { $0.contains("doesn't parse") })
        XCTAssertFalse(outcome.issues.contains { $0.contains("no entry point") })
    }

    func testMissingEntryPointIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: "const x = 1;"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("no entry point") })
    }

    // MARK: Permission cross-check

    func testUndeclaredModuleUseIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: """
            async function run(args, ctx) {
                const r = await ctx.fetch("https://example.com");
                return { title: r.body };
            }
            """))
        XCTAssertTrue(outcome.issues.contains { $0.contains("network") })
    }

    func testDeclaredAndUsedPermissionIsClean() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["network"]),
            entry: """
            async function run(args, ctx) {
                await ctx.fetch("https://example.com");
            }
            """))
        XCTAssertEqual(outcome.issues, [])
    }

    func testUnusedDeclaredPermissionIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["network"]),
            entry: "async function run() {}"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("network") && $0.contains("never uses")
        })
    }

    /// `invoque.fetch` inside a comment or string is not a use — masking must
    /// prevent the false positive.
    func testModuleMentionInCommentIsNotAUse() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: """
            // Could use invoque.fetch here if needed.
            async function run() { return { title: "invoque.shell" }; }
            """))
        XCTAssertEqual(outcome.issues, [])
    }

    func testUnknownModuleIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: "async function run(args, ctx) { ctx.teleport(); }"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("teleport") })
    }

    func testClipboardMethodsGateIndependently() {
        // Only .read is used — declaring both flags write as unused, and
        // declaring nothing flags read as undeclared.
        let script = "async function run(args, ctx) { ctx.clipboard.read(); }"

        let clean = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["clipboard.read"]), entry: script))
        XCTAssertEqual(clean.issues, [])

        let unusedWrite = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["clipboard.read", "clipboard.write"]),
            entry: script))
        XCTAssertTrue(unusedWrite.issues.contains {
            $0.contains("clipboard.write") && $0.contains("never uses")
        })

        let undeclared = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(), entry: script))
        XCTAssertTrue(undeclared.issues.contains { $0.contains("clipboard.read") })
    }

    /// Filter mode withholds side-effect modules even when declared.
    func testFilterModeRejectsShell() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(mode: "filter", permissions: ["shell"]),
            entry: "async function run(args, ctx) { ctx.shell.run(\"ls\"); }"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("shell") })
    }

    /// Always-available modules need no permission and count as used.
    func testAlwaysOnModulesNeedNoPermission() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: """
            async function run(args, ctx) {
                ctx.log("x");
                ctx.notify("y");
                ctx.storage.set("k", 1);
                return { title: String(ctx.args.length) };
            }
            """))
        XCTAssertEqual(outcome.issues, [])
    }
}
