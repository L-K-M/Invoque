import XCTest
@testable import Invoque

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
            guard !responses.isEmpty else { return "" }
            switch responses.removeFirst() {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }
    }

    private func makeModel(_ client: StubClient) -> MakerModel {
        MakerModel(client: { client },
                   runner: CommandRunner(),
                   writer: CommandWriter(rootURL: root),
                   store: store)
    }

    private func generationOutput(name: String = "gen-demo",
                                  permissions: [String] = [],
                                  usesClipboard: Bool = false) -> String {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let body = usesClipboard
            ? "const t = ctx.clipboard.read() ?? \"\"; return { title: t };"
            : "return { title: \"done\" };"
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
