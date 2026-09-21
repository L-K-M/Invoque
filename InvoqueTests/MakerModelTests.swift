import XCTest
@testable import Invoque

@MainActor
final class MakerModelTests: XCTestCase {

    private var root: URL!
    private var store: CommandStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-maker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CommandStore(rootPaths: [root.path])
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: Stub client

    /// Canned responses for `LLMClientServing`; captures the transcripts it
    /// was called with so tests can check the feedback loop.
    private final class StubClient: LLMClientServing {
        var model = "stub-model"
        var responses: [Result<String, Error>] = []
        var calls: [[LLMMessage]] = []

        func complete(messages: [LLMMessage]) async throws -> String {
            calls.append(messages)
            guard !responses.isEmpty else {
                // An unexpected extra call must fail loudly — returning ""
                // would surface as a confusing parse failure downstream.
                XCTFail("StubClient.complete called with no canned response queued")
                return ""
            }
            switch responses.removeFirst() {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }
    }

    private func makeModel(_ client: StubClient,
                           permissionGrants: CommandPermissionGrants? = nil) -> MakerModel {
        MakerModel(client: { client },
                   runner: CommandRunner(),
                   writer: CommandWriter(rootURL: root),
                   store: store,
                   permissionGrants: permissionGrants ?? makeFreshGrants())
    }

    /// An isolated grants store on a fresh suite, with teardown cleanup
    /// registered — same pattern as `PanelModelTests.makeFreshGrants`.
    private func makeFreshGrants() -> CommandPermissionGrants {
        let suiteName = "MakerModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return CommandPermissionGrants(defaults: defaults)
    }

    private func generationOutput(name: String = "gen-demo",
                                  permissions: [String] = [],
                                  usesClipboard: Bool = false,
                                  usesShell: Bool = false) -> String {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let body: String
        if usesShell {
            body = "const r = ctx.shell.run(\"echo hi\"); return { title: r.stdout.trim() };"
        } else if usesClipboard {
            body = "const t = ctx.clipboard.read() ?? \"\"; return { title: t };"
        } else {
            body = "return { title: \"done\" };"
        }
        return """
        --- command.json ---
        {
          "schemaVersion": 1, "name": "\(name)", "title": "Generated",
          "runtime": "js", "entry": "main.js", "mode": "action",
          "permissions": [\(list)]
        }
        --- main.js ---
        export default async function run(args, ctx) {
            \(body)
        }
        """
    }

    // MARK: Transitions

    func testCleanGenerationReachesReadyToSave() async {
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = makeModel(client)

        await model.start(prompt: "make a demo")
        let phase = await model.phase
        XCTAssertEqual(phase, .readyToSave)
        let draft = await model.draft
        XCTAssertEqual(draft?.manifest?.name, "gen-demo")
        // The transcript carries the system prompt + the user's prompt.
        XCTAssertEqual(client.calls.first?.count, 2)
    }

    func testUnparseableOutputFails() async {
        let client = StubClient()
        client.responses = [.success("no blocks here")]
        let model = makeModel(client)

        await model.start(prompt: "x")
        let phase = await model.phase
        XCTAssertEqual(phase, .failed)
        let error = await model.lastError
        XCTAssertTrue(error?.contains("command.json") == true)
    }

    func testTransportErrorFails() async {
        let client = StubClient()
        client.responses = [.failure(LLMError.missingAPIKey)]
        let model = makeModel(client)

        await model.start(prompt: "x")
        let phase = await model.phase
        XCTAssertEqual(phase, .failed)
        let error = await model.lastError
        XCTAssertTrue(error?.contains("API key") == true)
    }

    func testValidationIssuesLandInDraft() async {
        let client = StubClient()
        // Uses ctx.clipboard.read without declaring clipboard.read.
        client.responses = [.success(generationOutput(usesClipboard: true))]
        let model = makeModel(client)

        await model.start(prompt: "x")
        let phase = await model.phase
        XCTAssertEqual(phase, .draft)
        let issues = await model.draft?.issues
        XCTAssertTrue(issues?.contains { $0.contains("clipboard.read") } == true)
    }

    // MARK: Feedback loop

    func testFeedbackExtendsTranscriptAndRegenerates() async {
        let client = StubClient()
        client.responses = [
            .success("no blocks here"),
            .success(generationOutput()),
        ]
        let model = makeModel(client)

        await model.start(prompt: "make a demo")
        let failedPhase = await model.phase
        XCTAssertEqual(failedPhase, .failed)

        await model.sendFeedback("you forgot the code blocks")
        let phase = await model.phase
        XCTAssertEqual(phase, .readyToSave)
        // Second call: system + user + assistant(bad output) + user(feedback).
        XCTAssertEqual(client.calls[1].count, 4)
        XCTAssertEqual(client.calls[1].last?.role, .user)
        XCTAssertEqual(client.calls[1].last?.content, "you forgot the code blocks")
    }

    // MARK: Test run

    func testExplicitTestRunsDraft() async {
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = makeModel(client)

        await model.start(prompt: "x")
        await model.test()
        let result = await model.testResult
        XCTAssertEqual(result?.title, "done")
        let phase = await model.phase
        XCTAssertEqual(phase, .readyToSave)
    }

    func testDraftNeverRunsWithoutExplicitTest() async {
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = makeModel(client)

        await model.start(prompt: "x")
        // Generation + validation must not have executed the script —
        // testResult stays nil until the Test button.
        let result = await model.testResult
        XCTAssertNil(result)
    }

    // MARK: Permission consent

    /// A draft declaring `shell` pauses the test run for first-run consent
    /// — generated code is untrusted, so testing can't bypass the gate
    /// installed commands pass through.
    func testShellDraftPausesForConsent() async {
        let grants = makeFreshGrants()
        let client = StubClient()
        client.responses = [.success(generationOutput(permissions: ["shell"],
                                                      usesShell: true))]
        let model = makeModel(client, permissionGrants: grants)

        await model.start(prompt: "x")
        await model.test()

        let request = await model.permissionRequest
        XCTAssertEqual(request?.permissions, [.shell])
        let result = await model.testResult
        XCTAssertNil(result, "nothing must execute before consent")
        // The phase is untouched — the draft stays testable/saveable.
        let phase = await model.phase
        XCTAssertEqual(phase, .readyToSave)
    }

    /// Allow records the grant and runs the paused test with the same args.
    func testConfirmPermissionRequestRunsTest() async throws {
        // This test needs the suite name for the reload assertion below, so
        // it builds its own suite rather than using makeFreshGrants().
        let suiteName = "MakerModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let grants = CommandPermissionGrants(defaults: defaults)
        let client = StubClient()
        client.responses = [.success(generationOutput(permissions: ["shell"],
                                                      usesShell: true))]
        let model = makeModel(client, permissionGrants: grants)

        await model.start(prompt: "x")
        await model.test()
        let paused = await model.permissionRequest
        XCTAssertNotNil(paused)

        await model.confirmPermissionRequest()
        let result = await model.testResult
        XCTAssertEqual(result?.title, "hi")
        let cleared = await model.permissionRequest
        XCTAssertNil(cleared)
        // Allow must persist the grant, not just resume this run — a
        // regression here re-prompts on every test. `paused.command`'s
        // staging dir was deleted by the re-run's stage(), so check the
        // installed command: identical entry bytes → same grant key.
        await model.save()
        let installed = try Command(
            directory: root.appendingPathComponent("gen-demo"))
        // Read through a fresh instance over the same suite — the grant
        // must reach UserDefaults, not just an in-memory cache.
        let reloaded = CommandPermissionGrants(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertTrue(reloaded.ungranted(for: installed).isEmpty)
    }

    /// A second Test tap while the consent card is up must not silently
    /// replace the paused request — the paused snapshot and args stand until
    /// the user answers.
    func testSecondTestWhileConsentPendingKeepsPausedRequest() async throws {
        let grants = makeFreshGrants()
        let client = StubClient()
        client.responses = [.success(generationOutput(permissions: ["shell"],
                                                      usesShell: true))]
        let model = makeModel(client, permissionGrants: grants)

        await model.start(prompt: "x")
        await model.test()
        let paused = await model.permissionRequest
        XCTAssertNotNil(paused)

        await model.test()   // double-tap — must be a no-op
        let after = await model.permissionRequest
        // stage() uses a fresh UUID dir per run, so a replaced request
        // would point at a different entryURL — this equality is the
        // detection, not a tautology.
        XCTAssertEqual(after?.command.entryURL, paused?.command.entryURL)
        let result = await model.testResult
        XCTAssertNil(result, "the second test must not execute either")
    }

    /// Confirm must not grant when the draft can no longer run — a save()
    /// between pause and confirm flips phase to .saved; granting anyway would
    /// persist consent for code that never executed.
    func testConfirmAfterSaveRecordsNoGrant() async throws {
        let grants = makeFreshGrants()
        let client = StubClient()
        client.responses = [.success(generationOutput(permissions: ["shell"],
                                                      usesShell: true))]
        let model = makeModel(client, permissionGrants: grants)

        await model.start(prompt: "x")
        await model.test()
        let paused = await model.permissionRequest
        XCTAssertNotNil(paused)

        await model.save()   // phase → .saved, request left behind
        await model.confirmPermissionRequest()

        let cleared = await model.permissionRequest
        XCTAssertNil(cleared)
        let installed = try Command(
            directory: root.appendingPathComponent("gen-demo"))
        XCTAssertEqual(grants.ungranted(for: installed), [.shell],
                       "no grant may persist for a run that never happened")
        let result = await model.testResult
        XCTAssertNil(result)
    }

    func testDismissPermissionRequestLeavesDraftUntested() async {
        let grants = makeFreshGrants()
        let client = StubClient()
        client.responses = [.success(generationOutput(permissions: ["shell"],
                                                      usesShell: true))]
        let model = makeModel(client, permissionGrants: grants)

        await model.start(prompt: "x")
        await model.test()
        await model.dismissPermissionRequest()
        let request = await model.permissionRequest
        XCTAssertNil(request)
        let result = await model.testResult
        XCTAssertNil(result)
    }

    // MARK: Save

    func testSaveWritesCommandAndRescans() async {
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = makeModel(client)

        await model.start(prompt: "make a demo")
        await model.save()
        let phase = await model.phase
        XCTAssertEqual(phase, .saved)
        // The injected store picked the new command up via the explicit scan.
        XCTAssertTrue(store.commands.contains { $0.manifest.name == "gen-demo" })
        XCTAssertEqual(
            store.command(named: "gen-demo")?.manifest.generated?.prompt,
            "make a demo")
    }

    func testSaveIsRejectedWithIssues() async {
        let client = StubClient()
        client.responses = [.success(generationOutput(usesClipboard: true))]
        let model = makeModel(client)

        await model.start(prompt: "x")
        await model.save()
        let phase = await model.phase
        XCTAssertEqual(phase, .draft)  // unchanged — not saved
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("gen-demo").path))
    }

    /// A failed write keeps the draft saveable — the retry must not cost
    /// another LLM round-trip.
    func testSaveFailureKeepsDraftSaveable() async throws {
        // A writer whose root is a plain file — every save throws until
        // the file is removed.
        let blocker = root.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = MakerModel(client: { client },
                               runner: CommandRunner(),
                               writer: CommandWriter(rootURL: blocker),
                               store: nil,
                               permissionGrants: makeFreshGrants())

        await model.start(prompt: "demo")
        await model.save()
        var phase = await model.phase
        XCTAssertEqual(phase, .readyToSave)
        let lastError = await model.lastError
        XCTAssertNotNil(lastError)
        let draft = await model.draft
        XCTAssertNotNil(draft)

        try FileManager.default.removeItem(at: blocker)
        await model.save()
        phase = await model.phase
        XCTAssertEqual(phase, .saved)
        // One LLM call total — the save retry never re-generated.
        XCTAssertEqual(client.calls.count, 1)
    }

    /// Feedback after a failed regeneration must not re-append the same
    /// assistant turn — `lastRawOutput` is consumed when appended.
    func testFeedbackAfterFailedRoundDoesNotDuplicateAssistantTurn() async {
        let client = StubClient()
        client.responses = [
            .success(generationOutput()),
            .failure(LLMError.missingAPIKey),
            .success(generationOutput()),
        ]
        let model = makeModel(client)

        await model.start(prompt: "demo")
        await model.sendFeedback("first fix")
        let failedPhase = await model.phase
        XCTAssertEqual(failedPhase, .failed)
        await model.sendFeedback("second fix")

        // Third call's transcript: sys + user + assistant + user + user —
        // exactly one assistant turn, not two copies of the same output.
        let transcript = client.calls[2]
        XCTAssertEqual(transcript.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(transcript.last?.role, .user)
        XCTAssertEqual(transcript.last?.content, "second fix")
    }

    // MARK: Discard

    func testDiscardReturnsToIdle() async {
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = makeModel(client)

        await model.start(prompt: "x")
        await model.discard()
        let phase = await model.phase
        XCTAssertEqual(phase, .idle)
        let draft = await model.draft
        XCTAssertNil(draft)
    }

    /// ⏎ semantics: save when clean, generate when idle.
    func testPrimarySubmitGeneratesThenSaves() async {
        let client = StubClient()
        client.responses = [.success(generationOutput())]
        let model = makeModel(client)

        await model.primarySubmit(prompt: "make it")
        let midPhase = await model.phase
        XCTAssertEqual(midPhase, .readyToSave)
        await model.primarySubmit(prompt: "make it")
        let phase = await model.phase
        XCTAssertEqual(phase, .saved)
    }
}
