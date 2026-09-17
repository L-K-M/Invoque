import Foundation

/// The decoded outcome of one command invocation.
struct JSResult: Equatable {

    /// One row of a command's `{items: [...]}` result — Alfred's shape
    /// (PLAN §4.1). Items without a string `title` are dropped during
    /// decoding rather than failing the whole list.
    struct Item: Equatable {
        let title: String
        let subtitle: String?
        let icon: String?
        let arg: String?
    }

    /// What the script returned.
    enum Output: Equatable {
        /// Nothing, or a value with no mapped shape (a bare number, an
        /// object without `title`/`items`, …).
        case void
        /// `{title: "…"}` — a one-line result, e.g. for a HUD.
        case title(String)
        /// `{items: [...]}` — a result list.
        case items([Item])
    }

    /// Why an invocation produced no usable output. Script-level failures
    /// arrive here rather than as thrown errors so the captured logs travel
    /// with them.
    enum Failure: Error, Equatable, LocalizedError {
        /// Uncaught exception while evaluating or running the script.
        case exception(String)
        /// The returned promise rejected.
        case rejected(String)
        /// The timeout elapsed; the JSContext was abandoned. A tight
        /// synchronous loop keeps its queue's thread busy even now — the
        /// documented JavaScriptCore limitation (PLAN §4.2).
        case timedOut
        /// No callable `run` global after a successful evaluation.
        case missingEntryPoint

        var errorDescription: String? {
            switch self {
            case .exception(let message):
                return message
            case .rejected(let message):
                return message
            case .timedOut:
                return "the command timed out"
            case .missingEntryPoint:
                return "the script does not define a callable run function"
            }
        }
    }

    var output: Output
    var logs: [String]
    var error: Failure?

    /// Convenience for `.title(_)` — nil for other outputs.
    var title: String? {
        guard case .title(let title) = output else { return nil }
        return title
    }

    /// Convenience for `.items(_)` — nil for other outputs.
    var items: [Item]? {
        guard case .items(let items) = output else { return nil }
        return items
    }
}
