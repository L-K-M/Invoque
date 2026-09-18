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
        XCTAssertTrue(outcome.issues.first?.contains("command.json") == true,
                      "\(outcome.issues)")
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

    func testChecksRunOnManifestEntryNotParserEntry() {
        // manifest.entry names a generated file that isn't the parser's
        // pick — checks must run on the file the runtime will execute, so
        // index.js's broken source lands while main.js's clean one is only
        // syntax-checked as an extra file.
        let manifest = manifestJSON().replacingOccurrences(of: "\"main.js\"",
                                                           with: "\"index.js\"")
        let outcome = GeneratedCommandValidator.validate(GeneratedCommand(
            manifestJSON: manifest,
            entryName: "main.js",
            entrySource: "async function run() {}",
            extraFiles: ["index.js": "const broken ="]))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("index.js") && $0.contains("parse") })
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("index.js") && $0.contains("entry point") })
    }

    /// Non-entry files get the same syntax gate — a broken helper must be
    /// flagged even though the runtime starts at the entry file. It also
    /// earns the never-loaded warning: the runtime only evaluates the
    /// entry, so shipping a second .js at all is the issue.
    func testBrokenExtraFileIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(GeneratedCommand(
            manifestJSON: manifestJSON(),
            entryName: "main.js",
            entrySource: "async function run() {}",
            extraFiles: ["lib/helper.js": "const broken ="]))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("lib/helper.js") && $0.contains("doesn't parse") })
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("lib/helper.js") && $0.contains("never loaded") })
    }

    // MARK: JavaScript

    func testJSSyntaxErrorIsAnIssue() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: "async function run( {"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("doesn't parse") })
    }

    /// Compilation must not *run* the code — a top-level side effect (or
    /// infinite loop) can't hang or fire during validation. Time-bounded:
    /// if validation ever *does* run the script, the wait fails instead of
    /// hanging the test process on the loop.
    func testJSIsCompiledNotRun() {
        let finished = expectation(description: "validate returned")
        // Asserted after the wait — assertions inside the async closure
        // would fire late if validation ever ran the script past the
        // timeout, leaking the failure into whatever test runs next.
        nonisolated(unsafe) var outcome: GeneratedCommandValidator.Outcome?
        DispatchQueue.global().async {
            outcome = GeneratedCommandValidator.validate(self.generation(
                manifest: self.manifestJSON(),
                entry: """
                while (true) {}
                async function run() {}
                """))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        guard let outcome else {
            XCTFail("validate() did not return within the timeout — the script may have been executed")
            return
        }
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

    /// `apps.launch` per keystroke is the same footgun class as shell/paste —
    /// and even `apps.list()` is a disk scan outside the keystroke budget.
    func testFilterModeRejectsApps() {
        let outcome = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(mode: "filter", permissions: ["apps"]),
            entry: "async function run(args, ctx) { ctx.apps.list(); }"))
        XCTAssertTrue(outcome.issues.contains { $0.contains("apps") })
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

    // MARK: Aliasing heuristic

    /// Member access stays a direct, permission-visible call — only a bare
    /// hand-off of the bridge object is aliasing.
    func testMemberAccessIsNotAliasing() {
        let notify = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["notification"]),
            entry: """
            async function run(args, ctx) {
                return ctx.notify("done");
            }
            """))
        XCTAssertFalse(notify.issues.contains { $0.contains("alias") },
                       "\(notify.issues)")

        let bound = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["network"]),
            entry: """
            async function run(args, ctx) {
                const f = invoque.fetch;
                await f("https://example.com");
            }
            """))
        XCTAssertFalse(bound.issues.contains { $0.contains("alias") },
                       "\(bound.issues)")
    }

    /// `?.` is member access too — binding or returning through it is as
    /// permission-visible as the plain `.` form.
    func testOptionalChainedMemberAccessIsNotAliasing() {
        for entry in [
            "async function run(args, ctx) { const f = invoque?.fetch; }",
            "async function run(args, ctx) { return ctx?.notify(\"x\"); }",
        ] {
            let outcome = GeneratedCommandValidator.validate(generation(
                manifest: manifestJSON(permissions: ["network"]),
                entry: entry))
            XCTAssertFalse(outcome.issues.contains { $0.contains("alias") },
                           "\(entry): \(outcome.issues)")
        }
    }

    func testAliasingIsAnIssue() {
        for source in ["const inv = invoque", "const c = ctx",
                       "return ctx"] {
            let outcome = GeneratedCommandValidator.validate(generation(
                manifest: manifestJSON(),
                entry: "async function run(args, ctx) { \(source); }"))
            XCTAssertTrue(outcome.issues.contains { $0.contains("alias") },
                          "\(source): \(outcome.issues)")
        }
    }

    // MARK: Optional chaining

    /// `invoque?.fetch` is valid JS and must register the same permission
    /// requirement as `invoque.fetch` — runtime gating will deny it either
    /// way, so validation must not report clean.
    func testOptionalChainedModuleUseIsDetected() {
        let network = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(),
            entry: """
            async function run(args, ctx) {
                const r = await invoque?.fetch("https://example.com");
                return { title: "x" };
            }
            """))
        XCTAssertTrue(network.issues.contains { $0.contains("network") },
                      "\(network.issues)")

        let write = GeneratedCommandValidator.validate(generation(
            manifest: manifestJSON(permissions: ["clipboard.read"]),
            entry: """
            async function run(args, ctx) {
                await ctx?.clipboard?.write("x");
            }
            """))
        XCTAssertTrue(write.issues.contains { $0.contains("clipboard.write") },
                      "\(write.issues)")
    }
}
