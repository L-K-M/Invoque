import AppKit

/// Performs a picked row's action after the panel dismisses.
///
/// Kept out of `PanelModel`: the model is Foundation-only for tests, while
/// dispatch touches `NSWorkspace` and the pasteboard.
enum ActionPerformer {

    static func perform(_ action: Item.Action) {
        switch action {
        case .openApp(let url):
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    NSLog("Invoque: failed to open app at %@: %@",
                          url.path, error.localizedDescription)
                }
            }
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .copyText(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .system(let systemAction):
            SystemActionPerformer.perform(systemAction)
        case .runCommand(let name, _):
            // Intercepted by PanelController, which owns the runtime —
            // reaching here means a stray row bypassed the model's submit.
            NSLog("Invoque: runCommand '%@' reached ActionPerformer — ignored", name)
        case .enterFilter(let keyword):
            // Intercepted by PanelModel.submit (it expands the query rather
            // than dismissing); reaching here means the same bypass.
            NSLog("Invoque: enterFilter '%@' reached ActionPerformer — ignored", keyword)
        }
    }
}
