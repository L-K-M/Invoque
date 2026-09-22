import AppKit
import PictKit
import SwiftUI

/// The launcher panel's content: a rounded card with a search field on top, a
/// results list below, and key hints in the footer.
///
/// The search field is an `NSViewRepresentable` `NSTextField` rather than a
/// SwiftUI `TextField` + `@FocusState`: in a `.nonactivatingPanel` the panel
/// becomes key without the app activating, and SwiftUI's focus system does not
/// reliably follow that — keystrokes can end up dead while the field *looks*
/// focused. A plain `NSTextField` plus `window.makeFirstResponder(_:)` (see
/// `SearchTextField` and `PanelController.show`) is deterministic, and its
/// `doCommandBy` hook intercepts ↑/↓/⏎ before the field editor can
/// reinterpret them.
struct PanelView: View {

    @ObservedObject var model: PanelModel
    @ObservedObject var preferences: Preferences
    /// Live mirror of the system's Reduce Transparency/Motion settings — the
    /// themed fills and the selection animation are ours, so they adapt here
    /// rather than relying on the material to do it.
    @ObservedObject var a11y: AccessibilityDisplaySettings

    @Environment(\.colorScheme) private var colorScheme

    init(model: PanelModel, preferences: Preferences,
         a11y: AccessibilityDisplaySettings = .shared) {
        self.model = model
        self.preferences = preferences
        self.a11y = a11y
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, Metrics.fieldPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            if let request = model.permissionRequest {
                PermissionRequestCard(request: request,
                                      titleColor: titleColor,
                                      secondaryColor: secondaryColor,
                                      typeface: preferences.panelTypeface,
                                      onAllow: model.confirmPermissionRequest,
                                      onDecline: model.dismissPermissionRequest)
            } else if let confirmation = model.systemActionConfirmation {
                SystemActionConfirmationCard(
                    confirmation: confirmation,
                    titleColor: titleColor,
                    secondaryColor: secondaryColor,
                    typeface: preferences.panelTypeface,
                    onConfirm: model.confirmSystemAction,
                    onCancel: model.dismissSystemActionConfirmation)
            } else if model.makerIsActive, let maker = model.maker {
                MakerView(model: maker, prompt: model.makerPrompt ?? "",
                          titleColor: titleColor, secondaryColor: secondaryColor,
                          typeface: preferences.panelTypeface)
            } else {
                resultList
            }

            Divider().padding(.horizontal, 12)

            footer
                .padding(.horizontal, Metrics.fieldPadding)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .overlay(cardDecoration)
        .overlay(crtOverlay)
        // Transparent margin around the card so the window's shadow has room.
        .padding(Metrics.cardInset)
    }

    // MARK: Theme

    /// The card's background: Liquid Glass on macOS 26, a blurred panel below
    /// that, or the user's own fill for `solid`/`gradient`. Reduce Transparency
    /// forces the fill opaque — the colors stay, only the see-through goes.
    private var cardBackground: some View {
        PanelBackground(
            material: preferences.panelMaterial,
            tint: Color(hexString: preferences.tintHex),
            gradientColor: Color(hexString: preferences.gradientHex),
            gradientAngle: preferences.gradientAngle,
            opacity: AccessibilityDisplaySettings.effectiveBackgroundOpacity(
                configured: preferences.backgroundOpacity,
                reduceTransparency: a11y.reduceTransparency),
            cornerRadius: preferences.panelCornerRadius,
            reduceTransparency: a11y.reduceTransparency)
    }

    /// The retro corner flourish — ZX stripes, boing ball, … — drawn hugging a
    /// top corner and clipped flush by the card's rounded shape.
    @ViewBuilder
    private var cardDecoration: some View {
        if preferences.decorationStyle != .none {
            Group {
                switch preferences.decorationStyle.kind {
                case .stripes:
                    PanelDecoration(style: preferences.decorationStyle,
                                    position: preferences.decorationPosition,
                                    cornerRadius: preferences.panelCornerRadius,
                                    thickness: preferences.decorationSize)
                case .ball:
                    BoingBallDecoration(position: preferences.decorationPosition,
                                        cornerRadius: preferences.panelCornerRadius,
                                        diameter: Self.ballDiameter(decorationSize: preferences.decorationSize),
                                        pixelated: preferences.decorationStyle == .amigaPixel)
                }
            }
            .opacity(preferences.decorationOpacity)
            // Decorative: each style disables hit-testing internally, and the
            // guard here keeps any future case from swallowing header clicks.
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: preferences.panelCornerRadius,
                                        style: .continuous))
        }
    }

    /// The CRT scanline/vignette effect, drawn over the whole card — a
    /// phosphor-screen look, so it goes over the content too.
    @ViewBuilder
    private var crtOverlay: some View {
        if preferences.crtEnabled {
            CRTScreenOverlay(intensity: preferences.crtIntensity,
                             cornerRadius: preferences.panelCornerRadius)
        }
    }

    /// Approximate height of the header row — keep in sync with `searchField`'s
    /// font/padding if the header is ever restyled.
    static let headerRowHeight: CGFloat = 54

    /// The boing ball's diameter, proportional to the header like Zap's
    /// (`headerHeight × min(size × 0.12, 2)`).
    static func ballDiameter(decorationSize: Double) -> CGFloat {
        headerRowHeight * min(decorationSize * 0.12, 2)
    }

    /// Whether the theme owns the text color — true on `solid`/`gradient`,
    /// where the user picked the background outright. Glass materials defer to
    /// the system, which adapts `.primary` to the appearance automatically.
    private var usesThemeText: Bool {
        preferences.panelMaterial.usesThemeTextColor
    }

    private var titleColor: Color {
        usesThemeText ? Color(hexString: preferences.labelHex) : .primary
    }

    private var secondaryColor: Color {
        usesThemeText ? Color(hexString: preferences.labelHex).opacity(0.65) : .secondary
    }

    private var tertiaryColor: Color {
        usesThemeText ? Color(hexString: preferences.labelHex).opacity(0.45)
                      : Color(nsColor: .tertiaryLabelColor)
    }

    /// The configured highlight, or the system accent when the hex can't
    /// parse (defensive — `Preferences` validates on load).
    private var themeHighlight: NSColor {
        NSColor(hex: preferences.highlightHex) ?? .controlAccentColor
    }

    /// The selection fill for a row: the drawn icon's dominant color when
    /// adaptive accent is on, else the theme highlight. `image` is what the
    /// row renders — the shared-store resolution when Pict has one — so a
    /// custom icon glows with its own colors, not the system icon's.
    private func selectionFill(for image: NSImage?, key: String?) -> NSColor {
        if preferences.adaptiveAccent, let accent = AdaptiveAccent.color(for: image, key: key) {
            return accent
        }
        return themeHighlight
    }

    /// The bitmap to draw for an icon: the shared-store resolution when the
    /// store (or the bundle's un-jailed artwork) has one, else the cached
    /// workspace icon — `nil` is the resolver's "use the system icon"
    /// contract. `nil` only for `.symbol` rows, which draw vectors. A miss
    /// still warms the resolver, so a later redraw picks the artwork up.
    private func iconImage(for icon: Item.Icon) -> NSImage? {
        guard let path = icon.backingPath else { return nil }
        return icon.pictTarget.flatMap { model.iconResolver?($0) }
            ?? WorkspaceIcons.icon(forPath: path)
    }

    /// Text for the selected row, picked by the *composited* fill's luminance:
    /// at 25% opacity the card's own color dominates, so the highlight's raw
    /// luminance alone would often choose the wrong shade.
    private func selectedForeground(fill: NSColor) -> Color {
        Color.readableForeground(
            on: fill.composited(alpha: preferences.highlightOpacity,
                                over: selectionBaseColor))
    }

    /// What the selection fill blends over when computing text contrast: the
    /// card's own color for `solid`/`gradient`, a stand-in for the system
    /// material under glass (the real composite is unknown, but the material
    /// tracks the system appearance closely enough for the luminance choice).
    private var selectionBaseColor: NSColor {
        switch preferences.panelMaterial {
        case .solid:
            return NSColor(hex: preferences.tintHex) ?? .black
        case .gradient:
            return (NSColor(hex: preferences.tintHex) ?? .black)
                .composited(alpha: 0.5, over: NSColor(hex: preferences.gradientHex) ?? .black)
        case .liquidGlass, .glassClear, .glassTinted:
            return colorScheme == .dark
                ? (NSColor(hex: "#1C1C1E") ?? .black)
                : (NSColor(hex: "#F2F2F7") ?? .white)
        }
    }

    // MARK: Sections

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(secondaryColor)
            SearchField(
                text: $model.query,
                textColor: usesThemeText
                    ? (NSColor(hex: preferences.labelHex) ?? .labelColor)
                    : .labelColor,
                font: preferences.panelTypeface.nsFont(size: 22),
                onUp: { model.moveSelection(by: -1) },
                onDown: { model.moveSelection(by: 1) },
                onReturn: { model.submit(commandModifier: $0) }
            )
            // The representable's intrinsic size hugs the placeholder —
            // claim the row's width so the field doesn't resize per keystroke.
            .frame(maxWidth: .infinity)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.results.isEmpty {
                        // An empty query hasn't searched yet — hint instead
                        // of claiming there are no results.
                        Text(model.fileSearchTextIsBlank
                             ? "Type a filename"
                             : model.webSearchTextIsBlank
                             ? "Type a web search"
                             : model.fileScanIsPending
                             ? "Searching files…"
                             : model.fileSearchIsActive
                             ? "No matching files"
                             : model.query.isEmpty
                             ? "Search apps, commands, or the web"
                             : "No results")
                            .font(preferences.panelTypeface.font(.callout))
                            .foregroundStyle(tertiaryColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(model.results) { row in
                            let isSelected = model.selectedRow?.id == row.id
                            // Resolved once per row: the shared-store icon
                            // when there is one, else the workspace icon —
                            // one lookup feeds the drawn bitmap and, for
                            // the selected row, the accent sample.
                            let image = iconImage(for: row.icon)
                            let fill = isSelected
                                ? selectionFill(for: image, key: row.icon.backingPath)
                                : themeHighlight
                            let rowView = ResultRowView(row: row, iconImage: image,
                                          isSelected: isSelected,
                                          pinned: model.isPinned(row),
                                          fill: fill,
                                          fillOpacity: preferences.highlightOpacity,
                                          cornerRadius: preferences.highlightCornerRadius,
                                          titleColor: isSelected ? selectedForeground(fill: fill) : titleColor,
                                          subtitleColor: isSelected
                                              ? selectedForeground(fill: fill).opacity(0.75)
                                              : secondaryColor,
                                          typeface: preferences.panelTypeface,
                                          glows: isSelected && preferences.adaptiveAccent,
                                          showSourceBadge: true)
                                .id(row.id)
                                .onTapGesture {
                                    model.select(row)
                                    model.submit(detachesPendingScan: false)
                                }
                                .accessibilityAction {
                                    model.select(row)
                                    model.submit(detachesPendingScan: false)
                                }
                            // The menu attaches only to manageable entries —
                            // an empty `.contextMenu` still flashes a blank
                            // menu on right-click.
                            if model.canManage(row) {
                                rowView.contextMenu { entryMenuItems(for: row) }
                            } else {
                                rowView
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.edgePadding)
                .padding(.vertical, 8)
            }
            // The selection fill/glow eases between rows — suppressed
            // entirely under Reduce Motion.
            .animation(AccessibilityDisplaySettings.effectiveAnimation(
                .easeOut(duration: 0.1), reduceMotion: a11y.reduceMotion),
                       value: model.selectedRow?.id)
            // Arrow-key selection must keep the highlighted row visible.
            .scrollSelectionIntoView(model.selectedRow?.id, proxy: proxy)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            // Live status left, key hints right — the two clusters scan
            // separately instead of interleaving in one centered string.
            Text(footerStatus)
                .lineLimit(1)
            Spacer()
            Text(footerHint)
                .lineLimit(1)
        }
        .font(preferences.panelTypeface.font(.caption))
        .foregroundStyle(tertiaryColor)
    }

    /// The footer's left cluster: scan progress while a file walk
    /// streams, else the visible result count. Empty while a permission
    /// prompt or the maker owns the panel — the hint column is enough.
    private var footerStatus: String {
        if model.permissionRequest != nil || model.makerIsActive { return "" }
        if model.fileScanIsPending {
            return "Searching files…"
        }
        let count = model.results.count
        if count == 0 { return "" }
        return "\(count) \(count == 1 ? "result" : "results")"
    }

    /// The footer's key hints. The pin/block chords appear only while the
    /// selection is a manageable entry — advertising them on the web
    /// fallback would promise an action that can't apply.
    private var footerHint: String {
        if model.permissionRequest != nil { return "⌘⏎ allow · esc dismiss" }
        if model.systemActionConfirmation != nil {
            return "⌘⏎ confirm · esc dismiss"
        }
        if model.makerIsActive { return "⏎ generate/save · esc dismiss" }
        let manage = model.selectedRow.map(model.canManage) == true
            ? " · ⌘P pin · ⌘B block" : ""
        if model.fileSearchIsActive {
            // Mid-scan, ⏎ doesn't pick a row — it detaches the session
            // into its own window (see `PanelModel.submit`), so the hint
            // can't promise open/reveal until the walk settles.
            if model.fileScanIsPending {
                return "⏎ open in window" + manage + " · esc dismiss"
            }
            return "⏎ open · ⌘⏎ reveal in Finder" + manage + " · esc dismiss"
        }
        if model.webSearchIsActive {
            // A blank web query produces no rows, so Enter is a no-op —
            // the hint advertises typing, not the search chord.
            return model.webSearchTextIsBlank
                ? "type to search · esc dismiss"
                : "⏎ search the web · esc dismiss"
        }
        return "↑↓ navigate · ⏎ open" + manage + " · esc dismiss"
    }

    /// The pin/block menu for one row — attached only for manageable
    /// entries so right-click on a functional row doesn't flash an empty
    /// menu. Toggles show the HUD toast the chord path uses.
    @ViewBuilder
    private func entryMenuItems(for row: ResultRow) -> some View {
        Button(model.isPinned(row) ? "Unpin" : "Pin") {
            if let toast = model.togglePin(on: row) {
                HUD.show(toast, typeface: preferences.panelTypeface)
            }
        }
        Button("Block", role: .destructive) {
            if let toast = model.toggleBlock(on: row) {
                HUD.show(toast, typeface: preferences.panelTypeface)
            }
        }
    }
}

/// The first-run consent card for a command's risky permissions (PLAN
/// §4.3): what the command wants, spelled out per permission, then
/// Allow / Don't Run. ⌘⏎ (or the Allow button) grants; plain ⏎ is neutral.
private struct PermissionRequestCard: View {

    let request: CommandPermissionRequest
    let titleColor: Color
    let secondaryColor: Color
    /// The chosen typeface — resolved `Font`s come from `font(_:)`.
    let typeface: PanelTypeface
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(secondaryColor)
                VStack(alignment: .leading, spacing: 2) {
                    // The title is command-authored and could pose as a
                    // system prompt — the trusted attribution leads, the
                    // untrusted title follows it.
                    Text("Invoque command · \(request.command.name)")
                        .font(typeface.font(.caption2))
                        .foregroundStyle(secondaryColor)
                    Text(request.command.manifest.title)
                        .font(typeface.font(.headline))
                        .foregroundStyle(titleColor)
                    Text("wants to:")
                        .font(typeface.font(.caption))
                        .foregroundStyle(secondaryColor)
                }
            }
            ForEach(request.permissions, id: \.rawValue) { permission in
                Label(CommandPermissionGrants.consentLine(for: permission),
                      systemImage: "exclamationmark.triangle")
                    .font(typeface.font(.callout))
                    .foregroundStyle(titleColor)
                    .padding(.leading, 4)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Don't Run", action: onDecline)
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Metrics.edgePadding + 6)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: -

/// Confirmation for built-in actions that can destroy data or interrupt the
/// current login session. Plain Return is neutral; ⌘Return or the button acts.
private struct SystemActionConfirmationCard: View {

    let confirmation: SystemActionConfirmation
    let titleColor: Color
    let secondaryColor: Color
    let typeface: PanelTypeface
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: confirmation.symbolName)
                    .font(.title3)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Invoque system action")
                        .font(typeface.font(.caption2))
                        .foregroundStyle(secondaryColor)
                    Text(confirmation.title)
                        .font(typeface.font(.headline))
                        .foregroundStyle(titleColor)
                }
            }
            Text(confirmation.detail)
                .font(typeface.font(.callout))
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                Button(confirmation.confirmLabel,
                       role: .destructive,
                       action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(.horizontal, Metrics.edgePadding + 6)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: -

/// Layout constants for the card and its rows.
private enum Metrics {
    static let cardInset: CGFloat = 12
    static let edgePadding: CGFloat = 10
    static let fieldPadding: CGFloat = 20
}

// MARK: -

/// The search field as a plain `NSTextField` — see `PanelView`'s doc comment
/// for why not a SwiftUI `TextField`.
private struct SearchField: NSViewRepresentable {

    @Binding var text: String
    /// The theme's label color on materials that own the background, else the
    /// adaptive `.labelColor`.
    var textColor: NSColor
    /// The chosen typeface at the query size — resolved in `PanelView`.
    var font: NSFont
    var onUp: () -> Void
    var onDown: () -> Void
    /// `true` when ⌘ was held — consent cards need ⌘⏎ so a habitual
    /// double-⏎ can't record a permanent permission grant.
    var onReturn: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = "Search"
        field.font = font
        field.textColor = textColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        // Sync programmatic resets (query cleared on re-show) into the field.
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.textColor != textColor {
            field.textColor = textColor
        }
        if field.font != font {
            field.font = font
        }
    }

    // MARK: Coordinator

    /// Forwards field edits to the binding and navigation keys to the panel.
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onReturn(NSApp.currentEvent?.modifierFlags
                    .contains(.command) == true)
                return true
            default:
                // Everything else — notably `cancelOperation:` (Esc) — stays
                // with the responder chain, which reaches LauncherPanel.
                return false
            }
        }
    }
}

// MARK: -

/// The search field, which must own keyboard focus whenever the panel is
/// visible. Registers itself with the panel when it lands in a window: SwiftUI
/// may build the field only after the panel is on screen, so this hook (rather
/// than the controller alone) is what reliably captures focus on the first
/// summon. `PanelController.show` covers subsequent summons.
private final class SearchTextField: NSTextField {

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if let panel = window as? LauncherPanel {
            panel.preferredFirstResponder = self
        }
        // If the panel is already key (first summon), take focus immediately.
        // Restricted to LauncherPanel so previews or other hosts don't lose
        // their first responder to this field.
        if window is LauncherPanel, window.isKeyWindow {
            window.makeFirstResponder(self)
        }
    }
}
