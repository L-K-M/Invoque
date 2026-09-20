import SwiftUI

/// The Settings window's content. Grows tabs as features land — see PLAN.md §7.
struct SettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var makerSettings: MakerSettings
    @ObservedObject var updateChecker: UpdateChecker

    /// Draft of the API key field — written to Keychain only on Save.
    @State private var apiKeyDraft = ""
    /// Result line for "Test connection": nil = not run this session.
    @State private var connectionTestResult: String?
    /// The draft key the last test ran against — `nil` when the stored
    /// key was tested. Lets Save keep a still-accurate result line.
    @State private var connectionTestedDraft: String?
    @State private var connectionTestRunning = false

    init(preferences: Preferences,
         makerSettings: MakerSettings = .shared,
         updateChecker: UpdateChecker) {
        self.preferences = preferences
        self.makerSettings = makerSettings
        self.updateChecker = updateChecker
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceView(preferences: preferences)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
    }

    /// Launch behavior, updates, the Maker's LLM settings, and the version —
    /// the original single-form settings, now the General pane.
    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                Toggle("Keep query when the panel re-opens", isOn: $preferences.keepQueryOnReshow)
            }

            Section("Search") {
                Picker("Search engine", selection: $preferences.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                Text("The \"Search the web\" fallback row queries this engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            fileSearchSection

            entryRulesSection

            updatesSection

            makerSection

            Section {
                LabeledContent("Version") {
                    Text(Self.versionString)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Where `find`/`f`/`search` looks. The boot disk is searched through
    /// the home folder unless the whole-disk option is on; other drives
    /// are searched whole. The last enabled scope can't be turned off —
    /// file mode with nowhere to search could only ever show nothing.
    private var fileSearchSection: some View {
        Section("File Search") {
            Toggle("Home folder", isOn: scopeBinding(.home))
                .disabled(isSoleScope(.home))
            Toggle("Entire startup disk", isOn: scopeBinding(.system))
                .disabled(isSoleScope(.system))
            Toggle("External drives", isOn: scopeBinding(.volumes))
                .disabled(isSoleScope(.volumes))
            Text("The startup disk skips hidden folders and packages as usual; other drives are searched whole. Network shares are never walked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A Set-membership toggle — writes the scope in or out of the
    /// persisted set.
    private func scopeBinding(_ scope: FileSearch.Scope) -> Binding<Bool> {
        Binding(
            get: { preferences.fileSearchScopes.contains(scope) },
            set: { on in
                if on {
                    preferences.fileSearchScopes.insert(scope)
                } else {
                    preferences.fileSearchScopes.remove(scope)
                }
            })
    }

    /// Whether `scope` is the only enabled root — disabling its toggle
    /// keeps file search from being switched into an always-empty state.
    private func isSoleScope(_ scope: FileSearch.Scope) -> Bool {
        preferences.fileSearchScopes == [scope]
    }

    /// The pinned and blocked entry lists — the only place to undo a block
    /// (a blocked row can never be selected in the panel). Entries display
    /// by the title recorded at pin/block time, id beneath it.
    private var entryRulesSection: some View {
        Section("Pinned & Blocked") {
            if preferences.pinnedItems.isEmpty && preferences.blockedItems.isEmpty {
                Text("Right-click a result — or press ⌘P / ⌘B — to pin or block it. Pinned entries appear above other matches; blocked entries never appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !preferences.pinnedItems.isEmpty {
                Text("Pinned").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.sorted(preferences.pinnedItems), id: \.key) { id, title in
                    entryRow(id: id, title: title, actionTitle: "Unpin") {
                        preferences.pinnedItems[id] = nil
                    }
                }
            }
            if !preferences.blockedItems.isEmpty {
                Text("Blocked").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.sorted(preferences.blockedItems), id: \.key) { id, title in
                    entryRow(id: id, title: title, actionTitle: "Unblock") {
                        preferences.blockedItems[id] = nil
                    }
                }
            }
        }
    }

    /// One row of a pin/block list: the recorded title, the id it keys on,
    /// and the remove button.
    private func entryRow(id: String, title: String,
                          actionTitle: String,
                          action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(actionTitle, action: action)
                .accessibilityLabel("\(actionTitle) \(title)")
        }
    }

    /// A pin/block dict's entries sorted by title for a stable list.
    private static func sorted(_ entries: [String: String]) -> [(key: String, value: String)] {
        entries.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
        .map { (key: $0.key, value: $0.value) }
    }

    // MARK: Software updates

    /// Automatic GitHub release check toggle plus a manual "Check Now" and the
    /// last check timestamp — same UI pattern as Zap's GeneralView.
    private var updatesSection: some View {
        Section("Software updates") {
            Toggle("Automatically check for updates", isOn: $updateChecker.automaticChecksEnabled)
            HStack {
                Button("Check Now") { updateChecker.checkNow() }
                    .disabled(updateChecker.isChecking || updateChecker.isDownloading)
                if updateChecker.isChecking || updateChecker.isDownloading {
                    ProgressView().controlSize(.small)
                }
                if updateChecker.isDownloading {
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let date = updateChecker.lastCheckDate {
                    Text("Last checked \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Checks GitHub for new releases on launch and once a day. When an update is found you can download it straight to your Downloads folder (it's revealed in Finder), skip that version, or be reminded later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Maker (PLAN §7 AI section)

    /// Provider, base URL, model, and the Keychain-held API key the `make`
    /// command uses. The key field never displays the stored secret — only
    /// whether one is set.
    private var makerSection: some View {
        Section {
            Picker("Provider", selection: $makerSettings.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            TextField("Base URL", text: $makerSettings.baseURL)
            TextField("Model", text: $makerSettings.model)

            HStack(spacing: 8) {
                SecureField("API key", text: $apiKeyDraft)
                    .onSubmit(saveAPIKeyDraft)
                Button("Save", action: saveAPIKeyDraft)
                    .disabled(apiKeyDraft.isEmpty)
                // Clearing a stale secret needs an in-app path — assigning
                // "" deletes the Keychain item.
                if makerSettings.hasAPIKey {
                    Button("Remove", role: .destructive) {
                        makerSettings.apiKey = ""
                        connectionTestResult = nil
                    }
                }
            }
            Text(makerSettings.hasAPIKey ? "API key stored in Keychain" : "No API key set")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(connectionTestRunning ? "Testing…" : "Test connection") {
                    testConnection()
                }
                .disabled(connectionTestRunning)
                if let connectionTestResult {
                    Text(connectionTestResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("Maker (used by `make`)")
        } footer: {
            Text("Any OpenAI-compatible endpoint works — OpenAI, OpenRouter, Ollama (http://localhost:11434/v1), LM Studio. The API key is stored in Keychain, never on disk.")
                .font(.caption)
        }
    }

    private func saveAPIKeyDraft() {
        guard !apiKeyDraft.isEmpty else { return }
        makerSettings.apiKey = apiKeyDraft
        // The status line is only accurate for the draft actually tested —
        // editing after a test leaves it describing the wrong key.
        if apiKeyDraft != connectionTestedDraft { connectionTestResult = nil }
        apiKeyDraft = ""
    }

    private func testConnection() {
        // Test the draft when one's typed — but never persist it here: a
        // failed experiment must not clobber the stored working key, and
        // the field keeps its text so the user can fix and retry.
        let keyOverride = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        // The key this run describes — a late completion must not publish
        // a result for a key that's no longer stored or drafted (Save and
        // Remove can land while the request is in flight).
        let testedKey = keyOverride ?? makerSettings.apiKey
        // Same staleness axis for the endpoint: a baseURL or provider edit
        // mid-flight would show a result describing the old target.
        let testedBaseURL = makerSettings.baseURL
        let testedProvider = makerSettings.provider
        connectionTestRunning = true
        connectionTestResult = nil
        connectionTestedDraft = keyOverride
        let client = makerSettings.makeClient(keyOverride: keyOverride)
        Task { @MainActor in
            let result: String
            do {
                result = try await client.testConnection()
            } catch {
                result = error.localizedDescription
            }
            // Evaluated at completion: a Save/Remove that landed while
            // the request was in flight retires the result.
            if Self.shouldPublishTestResult(testedKey: testedKey,
                                            storedKey: makerSettings.apiKey,
                                            draft: apiKeyDraft),
               makerSettings.baseURL == testedBaseURL,
               makerSettings.provider == testedProvider {
                connectionTestResult = result
            }
            connectionTestRunning = false
        }
    }

    /// A late connection-test completion publishes only while the key it
    /// describes is still the stored key or the current draft — a Save or
    /// Remove mid-flight retires it.
    static func shouldPublishTestResult(testedKey: String,
                                        storedKey: String,
                                        draft: String) -> Bool {
        storedKey == testedKey || draft == testedKey
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default: return "dev"
        }
    }
}
