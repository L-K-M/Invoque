import Foundation

/// The face the rest of the app uses to execute commands — the panel's
/// search and action paths go through here rather than touching `JSRuntime`
/// directly.
final class CommandRunner {

    private let runtime: JSRuntime

    init(runtime: JSRuntime = JSRuntime()) {
        self.runtime = runtime
    }

    // MARK: Action mode

    /// Runs a command once and returns its decoded result. Every failure —
    /// script-level or infrastructure — arrives as `JSResult.error` with
    /// the captured logs attached.
    func run(command: Command, args: [String] = []) async -> JSResult {
        await runtime.run(command: command, args: args)
    }

    // MARK: Filter mode

    /// Runs a filter-mode command for one keystroke-state of the query —
    /// the text is passed as `args[0]` — and returns its result list. A
    /// script failure is thrown as `JSResult.Failure`.
    ///
    /// The runtime withholds side-effect modules (`shell`, `paste`) from
    /// filter-mode commands even when the manifest declares them — see
    /// `JSRuntime.execute` and PLAN §11.
    func query(command: Command, text: String) async throws -> [JSResult.Item] {
        let result = await runtime.run(command: command, args: [text])
        if let error = result.error {
            throw error
        }
        return result.items ?? []
    }
}
