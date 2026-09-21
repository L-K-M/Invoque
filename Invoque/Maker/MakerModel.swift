import Foundation

/// The `make` command's state machine — the panel shows `MakerView` for it
/// while the query is `make …`/`mk …` (PLAN §6).
///
/// Flow: `idle` → `generating` → `draft` (parsed + validated; `issues`
/// lists anything wrong) → `readyToSave` when issue-free → `saved`. A
/// `testing` run is always an explicit user action — generated code never
/// runs on arrival or on save. `failed` covers transport and parse errors;
/// the transcript is kept so `sendFeedback` can continue the conversation
/// from a failure too.
///
/// `@MainActor`: every mutation feeds SwiftUI directly, and the single
/// generation task means no lock is needed.
@MainActor
final class MakerModel: ObservableObject {

    enum Phase: Equatable {
        /// Nothing generated yet — the view shows the prompt + hint.
        case idle
        /// A request to the model is in flight.
        case generating
        /// A generation parsed and validated with `issues` to show.
        case draft
        /// An explicit test run of the draft is in flight.
        case testing
        /// The draft is issue-free; Save is enabled.
        case readyToSave
        /// `CommandWriter` wrote the command and the store rescanned.
        case saved
        /// Transport or parse failure — `lastError` holds the message.
        case failed
    }

    /// A parsed + validated generation. `manifest` is nil only when
    /// `command.json` didn't decode at all (the issue list says why).
    struct Draft: Equatable {
        let generation: GeneratedCommand
        let manifest: CommandManifest?
        let issues: [String]

        var isValid: Bool { issues.isEmpty && manifest != nil }
    }

    /// One completed generation round, for the session's history.
    struct Exchange: Equatable {
        let prompt: String
        let output: String
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var draft: Draft?
    /// The last explicit test run's result — cleared on regeneration.
    @Published private(set) var testResult: JSResult?
    @Published private(set) var lastError: String?
    /// The prompt that started the current draft's conversation.
    @Published private(set) var prompt = ""
    /// The model that produced the last response — provenance for save.
    @Published private(set) var lastUsedModel: String?
    /// Prompt/output pairs for every completed generation this session.
    @Published private(set) var sessionHistory: [Exchange] = []
    /// A test run paused on first-run consent for the draft's risky
    /// permissions — same gate the panel applies to installed commands
    /// (PLAN §4.3); generated code is untrusted, so testing can't bypass it.
    @Published private(set) var permissionRequest: CommandPermissionRequest?

    /// The conversation sent to the model: system prompt, the original
    /// request, then alternating assistant outputs and user feedback.
    /// Not `@Published` — nothing renders the raw turns; `sessionHistory`
    /// is the published projection for the view.
    private(set) var transcript: [LLMMessage] = []

    // Assigned once at init and frozen thereafter — `nonisolated` lets the
    // nonisolated init write them and keeps their reads out of the actor for
    // a set that can never change anyway. All five types are Sendable, so
    // the exemption is checked rather than unsafe.
    nonisolated private let clientProvider: @Sendable () -> LLMClientServing
    nonisolated private let runner: CommandRunner
    nonisolated private let writer: CommandWriter
    nonisolated private let store: CommandStore?
    nonisolated private let permissionGrants: CommandPermissionGrants

    private var generationTask: Task<Void, Never>?
    /// Temp directory the current draft is staged into for test runs.
    private var stagingDirectory: URL?
    /// The last raw model output — appended to the transcript as the
    /// assistant's turn when feedback loops back.
    private var lastRawOutput: String?
    /// Bumped by `reset()` — an in-flight `test()` whose suspension let a
    /// new session start must not publish its result or phase over the new
    /// state.
    private var epoch = 0

    /// `client` is a factory, not an instance, so each generation snapshots
    /// the current Settings (a mid-session model change applies at once).
    /// `store` is rescanned after a save; nil is fine for tests.
    /// Nonisolated so the model can be constructed off the main actor
    /// (AppDelegate's lazy panel factory, non-actor test helpers) — the
    /// stored `let`s it assigns are `nonisolated` above.
    nonisolated init(client: @escaping @Sendable () -> LLMClientServing,
         runner: CommandRunner,
         writer: CommandWriter,
         store: CommandStore? = nil,
         permissionGrants: CommandPermissionGrants) {
        self.clientProvider = client
        self.runner = runner
        self.writer = writer
        self.store = store
        self.permissionGrants = permissionGrants
    }

    // MARK: Generate

    /// What ⏎ in the search field means while the maker owns the panel:
    /// start when idle (or retry after save/failure), save when the draft
    /// is clean, nothing while busy or while issues remain — the feedback
    /// field is the way forward from `draft`.
    func primarySubmit(prompt: String) async {
        switch phase {
        case .idle, .saved, .failed:
            await start(prompt: prompt)
        case .readyToSave:
            save()
        case .generating, .testing, .draft:
            break
        }
    }

    /// Starts a fresh generation for `prompt`. A no-op while a generation
    /// is already in flight or the prompt is blank.
    func start(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase != .generating else { return }
        reset()
        self.prompt = trimmed
        transcript = [
            LLMMessage(.system, SystemPrompt.text),
            LLMMessage(.user, trimmed),
        ]
        await generate()
    }

    /// Regenerates with the existing transcript — the right retry for a
    /// transport failure, where the conversation is still the correct one
    /// and starting over would just lose it.
    func retry() async {
        guard !transcript.isEmpty, phase == .failed || phase == .idle else {
            return
        }
        await generate()
    }

    /// Feedback loop: appends the model's last output and the user's
    /// correction to the transcript, then regenerates. Only from `draft`,
    /// `readyToSave`, and `failed` — a malformed response is exactly what
    /// feedback is for; `saved`/`idle` sessions are done, and an in-flight
    /// `generating`/`testing` phase must not be interrupted mid-flight.
    func sendFeedback(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !transcript.isEmpty,
              phase == .draft || phase == .readyToSave || phase == .failed
        else { return }
        if let lastRawOutput {
            transcript.append(LLMMessage(.assistant, lastRawOutput))
            // Consumed — a failed regeneration must not re-append the same
            // assistant turn on the next feedback call.
            self.lastRawOutput = nil
        }
        transcript.append(LLMMessage(.user, trimmed))
        draft = nil
        testResult = nil
        await generate()
    }

    private func generate() async {
        phase = .generating
        lastError = nil
        let client = clientProvider()
        lastUsedModel = client.model
        let task = Task { await self.runGeneration(client: client) }
        generationTask = task
        await task.value
    }

    private func runGeneration(client: LLMClientServing) async {
        do {
            let output = try await client.complete(messages: transcript)
            try Task.checkCancellation()
            lastRawOutput = output
            // The last transcript entry is always the user turn that
            // triggered this round — the prompt on first generation, the
            // feedback text on revisions.
            sessionHistory.append(Exchange(
                prompt: transcript.last?.content ?? prompt, output: output))
            let generation = try GenerationParser.parse(output)
            let outcome = GeneratedCommandValidator.validate(generation)
            draft = Draft(generation: generation, manifest: outcome.manifest,
                          issues: outcome.issues)
            testResult = nil
            phase = draft?.isValid == true ? .readyToSave : .draft
        } catch is CancellationError {
            // discard() owns the phase; a cancelled in-flight generation
            // must not clobber the idle state it just set.
        } catch {
            // Cancellation surfaces differently per client — URLSession
            // throws URLError(.cancelled), not CancellationError. A task
            // discard() cancelled must never publish a phantom failure
            // over the state reset() just wrote.
            guard !Task.isCancelled else { return }
            lastError = error.localizedDescription
            phase = .failed
        }
    }

    // MARK: Test

    /// Runs the draft once in a disposable staging directory — never the
    /// commands root, so the store can't pick up a draft mid-test and the
    /// script's `data/` writes stay throwaway. Always user-triggered.
    func test(args: [String] = []) async {
        // A pending consent request holds phase at .draft/.readyToSave, so the
        // state guard alone would admit a second test() — silently replacing
        // the paused snapshot (and orphaning its staging dir).
        guard let draft, draft.manifest != nil,
              phase == .draft || phase == .readyToSave,
              permissionRequest == nil else { return }
        let epoch = self.epoch
        let result: JSResult
        do {
            let directory = try stage(draft)
            let command = try Command(directory: directory)
            // First-run consent applies to drafts too: generated code is
            // untrusted, so a shell/paste draft pauses for Allow before
            // anything executes.
            if let request = permissionGrants.consentRequest(for: command, args: args) {
                permissionRequest = request
                return
            }
            phase = .testing
            result = await runner.run(command: command, args: args)
        } catch {
            result = JSResult(output: .void, logs: [],
                              error: .exception(error.localizedDescription))
        }
        // The await above suspended: a discard/start in the meantime means
        // this result belongs to a draft that no longer exists.
        guard epoch == self.epoch else { return }
        testResult = result
        phase = draft.isValid ? .readyToSave : .draft
    }

    /// Consent granted for the paused test — records the grant and re-runs
    /// the same args (the check passes this time). The grant is recorded only
    /// when the draft can still run — a stale request must not persist a grant
    /// for code that never executes.
    func confirmPermissionRequest() async {
        guard let request = permissionRequest else { return }
        permissionRequest = nil
        guard phase == .draft || phase == .readyToSave,
              draft?.manifest != nil else { return }
        permissionGrants.grant(request)
        await test(args: request.args)
    }

    /// Declines the consent prompt: no grant, no test run.
    func dismissPermissionRequest() {
        permissionRequest = nil
    }

    /// Writes the draft's files into a fresh temp dir so `Command` can load
    /// and run them — the runtime reads the entry file from disk.
    private func stage(_ draft: Draft) throws -> URL {
        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-maker-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        for (name, contents) in draft.generation.files {
            // The validator already rejects unsafe names — this is a second
            // gate because stage() is also what feeds the code to the
            // runner.
            guard CommandWriter.isSafeRelativePath(name) else {
                throw CocoaError(.fileWriteInvalidFileName,
                                 userInfo: [NSLocalizedDescriptionKey:
                                            "rejected unsafe file path: \(name)"])
            }
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        stagingDirectory = directory
        return directory
    }

    // MARK: Save / discard

    /// Writes the draft into the commands root and rescans the store.
    /// Only possible on a clean draft — `readyToSave` implies `isValid`,
    /// which implies a decoded manifest.
    func save() {
        guard let draft, phase == .readyToSave, draft.manifest != nil else {
            return
        }
        do {
            // The writer re-decodes `generation.manifestJSON` itself — the
            // bytes it persists are the bytes it validates.
            try writer.save(draft.generation,
                            prompt: prompt, model: lastUsedModel ?? "")
        } catch {
            // The draft is still valid — a transient write error must not
            // burn it. Stay saveable: the error surfaces next to the draft
            // and ⏎ (primarySubmit → save) retries without a new LLM call.
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        // The watcher would rescan within ~0.3 s anyway; the explicit pass
        // makes the new command usable the instant the state flips.
        store?.scan()
        phase = .saved
    }

    /// Cancels an in-flight generation without discarding the session —
    /// the transcript survives so a resummoned `make …` can retry the same
    /// conversation. The panel calls this on dismiss: a hidden spinner
    /// would keep spending API budget for up to the request budget.
    /// No-op outside `.generating` — a test run isn't cancelled this way.
    /// `generate()` assigns `generationTask` in the same synchronous
    /// main-actor block that flips the phase, so observing `.generating`
    /// implies a tracked task — keep it that way (no suspension between
    /// the two writes) or this guard could desync them.
    func cancelGeneration() {
        guard phase == .generating else { return }
        generationTask?.cancel()
        generationTask = nil
        phase = .idle
    }

    /// Drops the draft and the conversation, back to `idle`.
    func discard() {
        generationTask?.cancel()
        generationTask = nil
        reset()
    }

    /// Shared teardown for `start` and `discard`.
    private func reset() {
        epoch += 1
        phase = .idle
        draft = nil
        testResult = nil
        lastError = nil
        prompt = ""
        transcript = []
        sessionHistory = []
        lastRawOutput = nil
        permissionRequest = nil
        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
            self.stagingDirectory = nil
        }
    }
}
