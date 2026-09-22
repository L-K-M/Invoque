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
    /// Themed text colors — the view sits inside the themed card, so on
    /// `solid`/`gradient` materials the theme's label color must replace the
    /// system colors or the text would go dark-on-dark. Semantic status
    /// colors (green/red) stay as-is.
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary
    /// The chosen typeface — `font(_:)` resolves each style. The `make`
    /// token and test-log output stay monospaced: they're code, not chrome.
    var typeface: PanelTypeface = .system

    @State private var feedback = ""
    @State private var testArgs = ""
    @State private var selectedSourceFile = ""
    @State private var sourceIsExpanded = true

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
                selectedSourceFile = ""
                sourceIsExpanded = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(secondaryColor)
            Text("make")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(secondaryColor)
            Text(displayedPrompt)
                .font(typeface.font(.headline))
                .foregroundStyle(titleColor)
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
                .font(typeface.font(.callout))
                .foregroundStyle(secondaryColor)
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
                .foregroundStyle(secondaryColor)
            // Up to the 300 s generation budget of silence needs an
            // escape hatch. discard() cancels the task; the typed prompt
            // stays in the query field, so ⏎ simply regenerates.
            Button("Cancel") { model.discard() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var savedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("The command is live — search for it by name. Esc dismisses; editing the query starts a new session.")
                .font(typeface.font(.caption))
                .foregroundStyle(secondaryColor)
            Button("Make another") { model.discard() }
        }
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Generation failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if let error = model.lastError {
                Text(error)
                    .font(typeface.font(.caption))
                    .foregroundStyle(secondaryColor)
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
            sourceReview(draft.generation)
            if !draft.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Offset identity, not string identity — two identical
                    // issue strings would collapse under `\.self`.
                    ForEach(Array(draft.issues.enumerated()), id: \.offset) { _, issue in
                        Text("· \(issue)")
                            .font(typeface.font(.caption))
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
                    .font(typeface.font(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The consent row replaces the action controls while pending —
            // same "card replaces content" pattern as the panel, so
            // "Allow & Test" is the only resume path.
            if let request = model.permissionRequest {
                permissionRow(request)
            } else {
                feedbackRow
                actionRow
            }
        }
    }

    /// Title, name, mode, permissions and file summary of the draft.
    private func draftSummary(_ draft: MakerModel.Draft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let manifest = draft.manifest {
                Text(manifest.title)
                    .font(typeface.font(.headline))
                HStack(spacing: 8) {
                    Text(manifest.name)
                    badge(manifest.mode.rawValue)
                    // Offset identity — duplicate permission strings in
                    // generated output must not collapse into one badge.
                    ForEach(Array(manifest.permissions.enumerated()), id: \.offset) { _, permission in
                        badge(permission)
                    }
                }
                .font(typeface.font(.caption))
                .foregroundStyle(secondaryColor)
            } else {
                Text("command.json didn't decode")
                    .font(typeface.font(.headline))
                    .foregroundStyle(.red)
            }
            Text(fileSummary(draft.generation))
                .font(typeface.font(.caption))
                .foregroundStyle(secondaryColor)
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

    /// Generated files stay visible before Save so inspectability is a real
    /// part of the Maker flow, not a promise that requires Finder or an editor.
    private func sourceReview(_ generation: GeneratedCommand) -> some View {
        let files = Self.reviewFiles(generation)
        let selected = Self.selectedFile(
            in: files,
            preferred: selectedSourceFile,
            entryName: generation.entryName)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                sourceIsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sourceIsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text("Review source")
                        .font(typeface.font(.callout).weight(.semibold))
                    Text("· \(files.count) \(files.count == 1 ? "file" : "files")")
                        .font(typeface.font(.caption))
                        .foregroundStyle(secondaryColor)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(titleColor)
            .accessibilityLabel("Review source")
            .accessibilityValue(
                "\(selected.name), \(sourceIsExpanded ? "expanded" : "collapsed")")

            if sourceIsExpanded {
                HStack(spacing: 6) {
                    Text("Generated code · review before saving")
                        .font(typeface.font(.caption))
                        .foregroundStyle(secondaryColor)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(files) { file in
                            Button(file.name) { selectedSourceFile = file.name }
                        }
                    } label: {
                        Label(selected.name, systemImage: "doc.plaintext")
                            .font(typeface.font(.caption))
                    }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                }

                ScrollView([.horizontal, .vertical]) {
                    Text(selected.contents.isEmpty
                         ? "(empty file)"
                         : Self.previewText(selected.contents))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(titleColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(8)
                }
                .frame(height: 150)
                .background(secondaryColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(secondaryColor.opacity(0.22), lineWidth: 1)
                }
            }
        }
    }

    struct ReviewFile: Identifiable, Equatable {
        let name: String
        let contents: String

        var id: String { name }
    }

    /// Stable file order keeps regeneration from shuffling the picker.
    static func reviewFiles(_ generation: GeneratedCommand) -> [ReviewFile] {
        var files = [
            ReviewFile(name: "command.json", contents: generation.manifestJSON),
            ReviewFile(name: generation.entryName, contents: generation.entrySource),
        ]
        // A directly constructed malformed draft can give both seed rows the
        // same name. Disambiguate instead of hiding either review surface.
        if generation.entryName == "command.json" {
            files[0] = ReviewFile(
                name: "command.json (manifest)",
                contents: generation.manifestJSON)
        }
        // Parser output already reserves these names. Keep the view helper
        // defensive because duplicate ids make SwiftUI's ForEach undefined.
        let reserved = Set(files.map(\.name))
        files.append(contentsOf: generation.extraFiles
            .filter { !reserved.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { ReviewFile(name: $0.key, contents: $0.value) })
        return files
    }

    /// Caps the preview so very large generated files can't stall layout.
    /// `index(offsetBy:limitedBy:)` bounds the scan — `count` would walk the
    /// whole string even when the answer is already clear at `limit`.
    static func previewText(_ contents: String, limit: Int = 200_000) -> String {
        guard let cut = contents.index(contents.startIndex,
                                       offsetBy: limit,
                                       limitedBy: contents.endIndex),
              cut < contents.endIndex
        else { return contents }
        return String(contents[..<cut])
            + "\n… preview truncated — save to see the full file"
    }

    /// A stale selection after regeneration falls back to executable source.
    static func selectedFile(in files: [ReviewFile], preferred: String,
                             entryName: String) -> ReviewFile {
        precondition(!files.isEmpty,
                     "reviewFiles always seeds the manifest and entry file")
        return files.first { $0.name == preferred }
            ?? files.first { $0.name == entryName }
            ?? files[0]
    }

    /// The paused-test consent row — same first-run gate the panel applies
    /// to installed commands (PLAN §4.3), because generated code is
    /// untrusted too. Allow records the grant and re-runs the test.
    private func permissionRow(_ request: CommandPermissionRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(secondaryColor)
            Text("Invoque command · \(request.command.name) wants to: "
                + request.permissions
                    .map { CommandPermissionGrants.consentLine(for: $0) }
                    .joined(separator: "; "))
                .font(typeface.font(.caption))
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Allow & Test") { Task { await model.confirmPermissionRequest() } }
                .buttonStyle(.borderedProminent)
            Button("Decline") { model.dismissPermissionRequest() }
        }
    }

    // MARK: Test

    @ViewBuilder
    private func testResultView(_ result: JSResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(resultSummary(result))
                .font(typeface.font(.callout))
                .foregroundStyle(result.error == nil ? titleColor : Color.red)
            if !result.logs.isEmpty {
                Text(result.logs.suffix(6).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(secondaryColor)
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
