import SwiftUI

/// The Settings window's content. Grows tabs as features land — see PLAN.md §7.
struct SettingsView: View {

    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                Toggle("Keep query when the panel re-opens", isOn: $preferences.keepQueryOnReshow)
            }

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
