import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The launcher's look: panel material, colors, selection, retro flourishes —
/// with a live preview of the real `PanelView` at the top (Zap's pattern), so
/// every slider and theme applies as the user watches.
struct AppearanceView: View {
    @ObservedObject var preferences: Preferences

    /// A small inert `PanelModel` feeding the preview a few sample rows.
    /// Nothing it can do matters — the preview swallows all hit-testing.
    @StateObject private var previewModel = AppearanceView.makePreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            PanelView(model: previewModel, preferences: preferences)
                .allowsHitTesting(false)
                .frame(height: 250)
                .frame(maxWidth: .infinity)
                .background(previewBackdrop)

            Divider()

            Form {
                presetsSection
                backgroundSection
                selectionSection
                textSection
                layoutSection
                decorationSection
                screenEffectSection
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Preview

    /// A desktop-picture-esque backdrop behind the preview card, so
    /// translucency and glass actually show through something.
    private var previewBackdrop: some View {
        LinearGradient(colors: [Color(hexString: "#46557A"), Color(hexString: "#1E2434")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func makePreviewModel() -> PanelModel {
        let model = PanelModel()
        // The preview draws what the launcher draws — shared-store icons
        // included, or the panel preview wouldn't preview the panel.
        model.iconResolver = { InvoqueIcons.shared.icon(for: $0) }
        let rows = [
            ResultRow(id: "preview.finder", title: "Finder", subtitle: "Application",
                      icon: .appIcon(path: "/System/Library/CoreServices/Finder.app",
                                   bundleID: "com.apple.finder"),
                      action: .copyText("")),
            ResultRow(id: "preview.calc", title: "Calculator", subtitle: "Application",
                      icon: .appIcon(path: "/System/Applications/Calculator.app",
                                   bundleID: "com.apple.calculator"),
                      action: .copyText("")),
            ResultRow(id: "preview.json", title: "Format Clipboard JSON", subtitle: "Invoque command",
                      icon: .symbol("terminal"),
                      action: .copyText("")),
            ResultRow(id: "preview.safari", title: "Safari", subtitle: "Application",
                      icon: .appIcon(path: "/Applications/Safari.app",
                                   bundleID: "com.apple.Safari"),
                      action: .copyText("")),
        ]
        model.showCommandResults(rows)
        model.select(rows[1])
        return model
    }

    // MARK: Sections

    private var presetsSection: some View {
        Section("Presets") {
            Menu("Apply a built-in theme") {
                ForEach(AppearancePreset.builtIns) { preset in
                    Button(preset.name) { preset.apply(to: preferences) }
                }
            }
            HStack {
                Button("Import…", action: importPreset)
                Button("Export…", action: exportPreset)
                Spacer()
                Button("Reset to Defaults", action: resetDefaults)
            }
            Text("Apply a ready-made theme, or save the current look as a shareable .json file. Jetty and Zap theme files import too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundSection: some View {
        Section("Background") {
            Picker("Material", selection: $preferences.panelMaterial) {
                ForEach(PanelMaterial.allCases) { material in
                    Text(material.label).tag(material)
                }
            }
            if preferences.panelMaterial.usesTintAndOpacity {
                ColorPicker("Tint", selection: colorBinding(\.tintHex), supportsOpacity: false)
                if preferences.panelMaterial == .gradient {
                    ColorPicker("Gradient end", selection: colorBinding(\.gradientHex), supportsOpacity: false)
                    HStack {
                        Text("Gradient direction")
                        Spacer()
                        Text("\(Int(preferences.gradientAngle.rounded()))°")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        AngleDial(angleDegrees: $preferences.gradientAngle)
                    }
                }
                sliderRow("Background opacity", value: $preferences.backgroundOpacity, range: 0...1)
            } else {
                Text("System glass picks its own color and opacity — the tint controls apply to Tinted glass, Solid, and Gradient.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectionSection: some View {
        Section("Selection") {
            ColorPicker("Highlight", selection: colorBinding(\.highlightHex), supportsOpacity: false)
            sliderRow("Highlight opacity", value: $preferences.highlightOpacity, range: 0...1)
            Toggle("Adaptive accent", isOn: $preferences.adaptiveAccent)
            Text("When on, the selected row borrows its icon's dominant color — Safari glows orange, Terminal dark. The Highlight color is the fallback for rows without icons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        Section("Text") {
            Picker("Typeface", selection: $preferences.panelTypeface) {
                // Each option draws in its own face, like a font menu.
                ForEach(PanelTypeface.curated) { typeface in
                    Text(typeface.label).font(typeface.font(.body)).tag(typeface)
                }
                Divider()
                // Every other installed family — user fonts included.
                ForEach(PanelTypeface.moreFamilies, id: \.self) { family in
                    let typeface = PanelTypeface.custom(family)
                    Text(typeface.label).font(typeface.font(.body)).tag(typeface)
                }
            }
            ColorPicker("Label", selection: colorBinding(\.labelHex), supportsOpacity: false)
                .disabled(!preferences.panelMaterial.usesThemeTextColor)
            if !preferences.panelMaterial.usesThemeTextColor {
                Text("Applies to Solid and Gradient backgrounds — glass materials use the system's own text color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            sliderRow("Panel corner radius", value: $preferences.panelCornerRadius, range: 0...32, step: 1)
            sliderRow("Highlight corner radius", value: $preferences.highlightCornerRadius, range: 0...32, step: 1)
        }
    }

    private var decorationSection: some View {
        Section("Decoration") {
            Picker("Style", selection: $preferences.decorationStyle) {
                ForEach(DecorationStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            if preferences.decorationStyle != .none {
                Picker("Position", selection: $preferences.decorationPosition) {
                    ForEach(DecorationPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                sliderRow("Size", value: $preferences.decorationSize, range: 4...30, step: 1)
                sliderRow("Opacity", value: $preferences.decorationOpacity, range: 0...1)
            }
        }
    }

    private var screenEffectSection: some View {
        Section("Screen effect") {
            Toggle("CRT scanlines", isOn: $preferences.crtEnabled)
            if preferences.crtEnabled {
                sliderRow("Intensity", value: $preferences.crtIntensity, range: 0...1)
            }
        }
    }

    // MARK: Controls

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double = 0.01) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue, range: range))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func format(_ value: Double, range: ClosedRange<Double>) -> String {
        range.upperBound <= 1 ? String(format: "%.0f%%", value * 100) : String(format: "%.0f", value)
    }

    // MARK: Bindings

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<Preferences, String>) -> Binding<Color> {
        Binding(
            get: { Color(hexString: preferences[keyPath: keyPath]) },
            set: { preferences[keyPath: keyPath] = NSColor($0).hexString }
        )
    }

    // MARK: Presets

    /// Writes the current appearance to a user-chosen `.json` file.
    private func exportPreset() {
        let preset = AppearancePreset(name: "Invoque Theme", from: preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(preset) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Invoque Theme.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Reads a `.json` theme file and applies it (validating every value).
    /// Accepts Jetty and Zap theme files too — see `AppearancePreset.decode`.
    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        guard let preset = AppearancePreset.decode(from: data) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't Import Theme"
            alert.informativeText = "\"\(url.lastPathComponent)\" doesn't look like an Invoque, Jetty, or Zap theme file."
            alert.runModal()
            return
        }
        preset.apply(to: preferences)
    }

    private func resetDefaults() {
        preferences.resetAppearanceToDefaults()
    }
}
