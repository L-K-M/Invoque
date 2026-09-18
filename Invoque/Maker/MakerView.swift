import AppKit
import SwiftUI

/// The Maker's in-panel view (PLAN §6): replaces the results list while the
/// query is `make …`/`mk …`. Shows the generation pipeline state — spinner
/// while generating, the parsed draft summary with validation issues, an
/// explicit Test run, a feedback line for the regenerate loop, and
/// Save/Discard. Generated code never runs by itself — Test is the only
/// execution path and is always a deliberate click.
struct MakerView: View {

    @ObservedObject var model: MakerModel
    /// The text after `make `/`mk ` in the query right now.
    let prompt: String

    @State private var feedback = ""
    @State private var testArgs = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                switch model.phase {
                case .idle:
                    idleContent
                case .generating:
                    generatingContent
                case .draft, .testing, .readyToSave:
                    draftContent
                case .saved:
                    savedContent
                case .failed:
                    failedContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        // `.task(id:)` rather than `.onChange`: the non-deprecated
        // signature needs macOS 14 and we target 13. The view stays
        // mounted across discard-and-retype, so per-session fields are
        // cleared when the model returns to `.idle`.
        .task(id: model.phase) {
            if model.phase == .idle {
                feedback = ""
                testArgs = ""
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.secondary)
            Text("make")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(displayedPrompt)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// The prompt that produced the draft once a session is running, else
    /// the live query text — a new `make …` line after a finished session
    /// shows what the user is typing, not the old session's prompt.
    private var displayedPrompt: String {
        switch model.phase {
        case .idle, .saved:
            return prompt
        case .generating, .draft, .testing, .readyToSave, .failed:
            return model.prompt.isEmpty ? prompt : model.prompt
        }
    }

    // MARK: Phase content

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the command, then press ⏎ to generate it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Generate") {
                Task { await model.primarySubmit(prompt: prompt) }
            }
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var generatingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Generating with \(model.lastUsedModel ?? "the model")…")
                .foregroundStyle(.secondary)
        }
    }

    private var savedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("The command is live — search for it by name. Esc dismisses; editing the query starts a new session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Make another") { model.discard() }
        }
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Generation failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            feedbackRow
            HStack(spacing: 10) {
                // Retry replays the same transcript — a transport flake
                // shouldn't lose the conversation.
                Button("Retry") {
                    Task { await model.retry() }
                }
                Button("Discard") { model.discard() }
            }
        }
    }

    // MARK: Draft

    @ViewBuilder
    private var draftContent: some View {
        if let draft = model.draft {
            draftSummary(draft)
            if !draft.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Offset identity, not string identity — two identical
                    // issue strings would collapse under `\.self`.
                    ForEach(Array(draft.issues.enumerated()), id: \.offset) { _, issue in
                        Text("· \(issue)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let result = model.testResult {
                testResultView(result)
            }
            // A failed save leaves the phase at readyToSave — the error
            // shows here, and Save/⏎ retries.
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            feedbackRow
            actionRow
        }
    }

    /// Title, name, mode, permissions and file summary of the draft.
    private func draftSummary(_ draft: MakerModel.Draft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let manifest = draft.manifest {
                Text(manifest.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(manifest.name)
                    badge(manifest.mode.rawValue)
                    // Offset identity — duplicate permission strings in
                    // generated output must not collapse into one badge.
                    ForEach(Array(manifest.permissions.enumerated()), id: \.offset) { _, permission in
                        badge(permission)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("command.json didn't decode")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            Text(fileSummary(draft.generation))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func fileSummary(_ generation: GeneratedCommand) -> String {
        let lines = generation.entrySource.components(separatedBy: "\n").count
        var parts = ["\(generation.entryName) · \(lines) lines"]
        if !generation.extraFiles.isEmpty {
            parts.append("+ \(generation.extraFiles.keys.sorted().joined(separator: ", "))")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: Test

    @ViewBuilder
    private func testResultView(_ result: JSResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(resultSummary(result))
                .font(.callout)
                .foregroundStyle(result.error == nil ? Color.primary : Color.red)
            if !result.logs.isEmpty {
                Text(result.logs.suffix(6).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func resultSummary(_ result: JSResult) -> String {
        if let error = result.error {
            return "Test failed: \(error.localizedDescription)"
        }
        switch result.output {
        case .void:
            return "Test passed — no output"
        case .title(let title):
            return "Test passed — “\(title)”"
        case .items(let items):
            let preview = items.prefix(3).map(\.title).joined(separator: ", ")
            return "Test passed — \(items.count) items\(preview.isEmpty ? "" : ": \(preview)")"
        }
    }

    // MARK: Feedback & actions

    private var feedbackRow: some View {
        HStack(spacing: 8) {
            InlineField(text: $feedback,
                        placeholder: "Feedback — e.g. “broke on empty clipboard”",
                        onCommit: sendFeedback)
            Button("Regenerate", action: sendFeedback)
                .disabled(feedback.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            InlineField(text: $testArgs,
                        placeholder: "test args (optional)",
                        onCommit: runTest)
            .frame(maxWidth: 180)
            if model.phase == .testing {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("Test", action: runTest)
                    .disabled(model.draft?.manifest == nil
                              || (model.phase != .draft && model.phase != .readyToSave))
            }
            Spacer(minLength: 0)
            Button("Discard") { model.discard() }
            // ⏎ in the search field already routes here via
            // `PanelModel.submit` → `primarySubmit`; a key equivalent on the
            // button would intercept Return before the field sees it.
            Button("Save") { model.save() }
                .disabled(model.phase != .readyToSave)
        }
    }

    private func runTest() {
        Task { await model.test(args: Self.parseArgs(testArgs)) }
    }

    /// Whitespace splitting that honors single/double quotes, so
    /// `--text "two words"` arrives as one argument. An unmatched quote
    /// swallows the rest of the field — the user's intent is unambiguous.
    static func parseArgs(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        // A quoted empty string is still an argument — `--text ""` must
        // arrive as "" rather than being dropped at the flush points.
        var sawQuote = false
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                sawQuote = true
            } else if ch.isWhitespace {
                if !current.isEmpty || sawQuote {
                    args.append(current); current = ""; sawQuote = false
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty || sawQuote { args.append(current) }
        return args
    }

    private func sendFeedback() {
        let text = feedback.trimmingCharacters(in: .whitespaces)
        // Return in the field must not bypass the Regenerate button's
        // disabled-when-empty guard — an empty turn still costs a call.
        guard !text.isEmpty else { return }
        feedback = ""
        Task { await model.sendFeedback(text) }
    }
}

// MARK: -

/// A plain `NSTextField` for the Maker's secondary inputs — same reasoning
/// as the panel's search field: in a `.nonactivatingPanel`, a SwiftUI
/// `TextField`'s focus is unreliable. Return commits; all other keys (arrows
/// included) keep their normal text-editing behavior.
private struct InlineField: NSViewRepresentable {

    @Binding var text: String
    let placeholder: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineField

        init(_ parent: InlineField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}
