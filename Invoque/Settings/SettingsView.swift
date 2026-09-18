import SwiftUI

/// The Settings window's content. Grows tabs as features land — see PLAN.md §7.
struct SettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var makerSettings: MakerSettings

    /// Draft of the API key field — written to Keychain only on Save.
    @State private var apiKeyDraft = ""
    /// Result line for "Test connection": nil = not run this session.
    @State private var connectionTestResult: String?
    @State private var connectionTestRunning = false

    init(preferences: Preferences, makerSettings: MakerSettings = .shared) {
        self.preferences = preferences
        self.makerSettings = makerSettings
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                Toggle("Keep query when the panel re-opens", isOn: $preferences.keepQueryOnReshow)
            }

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
        apiKeyDraft = ""
    }

    private func testConnection() {
        // Test the draft when one's typed — but never persist it here: a
        // failed experiment must not clobber the stored working key, and
        // the field keeps its text so the user can fix and retry.
        let keyOverride = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        connectionTestRunning = true
        connectionTestResult = nil
        let client = makerSettings.makeClient(keyOverride: keyOverride)
        Task { @MainActor in
            do {
                let status = try await client.testConnection()
                connectionTestResult = status
            } catch {
                connectionTestResult = error.localizedDescription
            }
            connectionTestRunning = false
        }
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
