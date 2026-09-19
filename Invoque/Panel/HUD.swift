import AppKit

/// Transient one-line overlay — the "HUD" an action-mode command's
/// `{title}` result (or a failure message) renders as (PLAN §4.1).
/// Non-activating, centered on the screen under the mouse, auto-dismisses.
enum HUD {

    /// How long the overlay stays up before fading out.
    private static let visibleSeconds: TimeInterval = 1.6
    private static let fadeSeconds: TimeInterval = 0.25

    /// Shows `text` briefly near the screen under the mouse. Re-show
    /// replaces the current overlay rather than stacking. Callable from
    /// any context — the AppKit work always happens on the main queue.
    /// `font` defaults to the system face; the panel passes the chosen
    /// typeface so the toast reads in the launcher's voice.
    static func show(_ text: String,
                     font: NSFont = .systemFont(ofSize: 16, weight: .medium)) {
        Task { @MainActor in present(text, font: font) }
    }

    @MainActor
    private static func present(_ text: String, font: NSFont) {
        dismiss()

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        let padding = NSSize(width: 40, height: 22)
        let contentSize = NSSize(
            width: min(label.fittingSize.width + padding.width, 560),
            height: label.fittingSize.height + padding.height)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        label.frame = NSRect(
            x: padding.width / 2,
            y: padding.height / 2,
            width: contentSize.width - padding.width,
            height: label.fittingSize.height)
        effect.addSubview(label)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = effect
        // Informational only — never eat clicks aimed at what's underneath.
        panel.ignoresMouseEvents = true

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - contentSize.width / 2,
                y: frame.midY - contentSize.height / 2))
        }

        current = panel
        panel.orderFrontRegardless()

        // A second show() during the window must not have its panel
        // dismissed early by the first show's timer.
        generation += 1
        let shown = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(visibleSeconds * 1_000_000_000))
            // try? swallows cancellation — a cancelled timer must abandon,
            // not fall through to an early dismiss.
            if generation == shown, !Task.isCancelled { dismiss() }
        }
    }

    // MARK: Internals

    @MainActor private static var current: NSPanel?
    @MainActor private static var generation = 0

    @MainActor
    private static func dismiss() {
        guard let panel = current else { return }
        current = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeSeconds
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}
