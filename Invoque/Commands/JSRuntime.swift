import Foundation
import JavaScriptCore

/// Executes a command's entry script on JavaScriptCore.
///
/// Each invocation owns a fresh `JSContext` on a fresh serial `DispatchQueue`
/// — a JSContext is not thread-safe, so every JSValue the run produces is
/// touched only from that queue. Nothing is shared between invocations;
/// `invoque.storage` is the persistence path (PLAN §4.2).
final class JSRuntime {

    /// Wall-clock limit per invocation. On expiry the context is abandoned:
    /// JavaScriptCore cannot interrupt a tight synchronous loop, so a stuck
    /// script may keep its queue's thread busy — the caller still gets
    /// `.timedOut` and later invocations are unaffected.
    var defaultTimeout: TimeInterval

    init(defaultTimeout: TimeInterval = 10) {
        self.defaultTimeout = defaultTimeout
    }

    /// Failures that prevent producing a `JSResult` at all. Script-level
    /// failures (exceptions, rejections, timeouts) are `JSResult.error`
    /// instead, so the captured logs travel with them.
    enum RuntimeError: Error, Equatable, LocalizedError {
        /// The entry file could not be read as UTF-8.
        case entryUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .entryUnreadable(let path):
                return "could not read entry file at \(path)"
            }
        }
    }

    // MARK: Running

    /// Runs `run(args, ctx)` from the command's entry script and awaits the
    /// promise it returns. Returns a `JSResult` carrying the decoded output,
    /// the captured log lines, and any script-level failure.
    func run(command: Command, args: [String] = [], timeout: TimeInterval? = nil) async throws -> JSResult {
        guard let data = try? Data(contentsOf: command.entryURL),
              let source = String(data: data, encoding: .utf8) else {
            throw RuntimeError.entryUnreadable(command.entryURL.path)
        }

        let logs = CommandLog()
        return await withCheckedContinuation { (continuation: CheckedContinuation<JSResult, Never>) in
            let box = CompletionBox(continuation: continuation)
            let queue = DispatchQueue(label: "com.invoque.js.\(command.name)")
            queue.async {
                self.execute(source: source, command: command, args: args,
                             logs: logs, box: box, queue: queue)
            }
            // The timer deliberately runs off the JS queue: it must still
            // fire when the queue is stuck inside synchronous JavaScript.
            DispatchQueue.global().asyncAfter(deadline: .now() + (timeout ?? defaultTimeout)) {
                box.complete(JSResult(output: .void, logs: logs.snapshot, error: .timedOut))
            }
        }
    }

    // MARK: Execution (JS queue)

    /// The whole invocation, top to bottom, on `queue`.
    private func execute(source: String, command: Command, args: [String],
                         logs: CommandLog, box: CompletionBox, queue: DispatchQueue) {
        guard let context = JSContext() else {
            box.complete(JSResult(output: .void, logs: logs.snapshot,
                                  error: .exception("JavaScriptCore context creation failed")))
            return
        }

        // evaluateScript doesn't throw; uncaught exceptions land here.
        var exceptionMessage: String?
        context.exceptionHandler = { _, value in
            exceptionMessage = value?.toString() ?? "Unknown JavaScript exception"
        }

        installConsole(in: context, logs: logs)
        installHelpers(in: context)

        // A filter command re-runs on every keystroke, so side-effectful
        // modules are withheld even when declared — a keystroke-driven side
        // effect is a footgun (PLAN §11). `paste` is in the same class and is
        // only a stub anyway.
        var permissions = command.permissions
        if command.manifest.mode == .filter {
            permissions.remove(.shell)
            permissions.remove(.paste)
        }
        let contextObject = InvoqueBridge.install(in: context, command: command, args: args,
                                                  permissions: permissions, logs: logs,
                                                  callbackQueue: queue)

        _ = context.evaluateScript(Self.preprocess(source))
        if let message = exceptionMessage {
            box.complete(JSResult(output: .void, logs: logs.snapshot, error: .exception(message)))
            return
        }

        // `run` comes from a top-level `function run`/`async function run`
        // declaration, or from the `export default` transform.
        let isCallable = context.evaluateScript("typeof run === 'function'")?.toBool() ?? false
        guard isCallable, let runFunction = context.objectForKeyedSubscript("run") else {
            box.complete(JSResult(output: .void, logs: logs.snapshot, error: .missingEntryPoint))
            return
        }

        let contextArgument: Any
        if let contextObject {
            contextArgument = contextObject
        } else {
            contextArgument = NSNull()
        }
        let returned: JSValue? = runFunction.call(withArguments: [args, contextArgument])
        if let message = exceptionMessage {
            box.complete(JSResult(output: .void, logs: logs.snapshot, error: .exception(message)))
            return
        }
        guard let returned, Self.isThenable(returned, in: context) else {
            box.complete(JSResult(output: Self.decode(returned), logs: logs.snapshot, error: nil))
            return
        }

        // Promise path: park the result in `then` callbacks. The native
        // handlers are installed as globals via setValue — the same bridging
        // path every `invoque.*` method uses — rather than passed inside an
        // invokeMethod arguments array, where block-to-function bridging is
        // unreliable and a non-callable argument makes `then` silently adopt
        // the promise state (the invocation hangs until timeout).
        let fulfill: @convention(block) (JSValue?) -> Void = { value in
            box.complete(JSResult(output: Self.decode(value), logs: logs.snapshot, error: nil))
        }
        let reject: @convention(block) (JSValue?) -> Void = { value in
            let message = value?.toString() ?? "Promise rejected without a reason"
            box.complete(JSResult(output: .void, logs: logs.snapshot, error: .rejected(message)))
        }
        context.globalObject.setValue(fulfill, forProperty: "__invoque_fulfill")
        context.globalObject.setValue(reject, forProperty: "__invoque_reject")
        context.globalObject.setValue(returned, forProperty: "__invoque_pending")
        _ = context.evaluateScript("__invoque_pending.then(__invoque_fulfill, __invoque_reject)")
        if let message = exceptionMessage {
            box.complete(JSResult(output: .void, logs: logs.snapshot, error: .exception(message)))
        }
    }

    // MARK: Setup

    /// `console.log/info/warn/error` → the invocation's `CommandLog`.
    private func installConsole(in context: JSContext, logs: CommandLog) {
        guard let console = JSValue(newObjectIn: context) else { return }
        for level in ["log", "info", "warn", "error"] {
            let write: @convention(block) () -> Void = {
                logs.append("[console.\(level)] \(InvoqueBridge.joinedArguments())")
            }
            console.setValue(write, forProperty: level)
        }
        context.globalObject.setValue(console, forProperty: "console")
    }

    /// JS-side helpers used by the runtime itself.
    private func installHelpers(in context: JSContext) {
        _ = context.evaluateScript("""
            function __invoque_isThenable(value) {
                return value !== null && value !== undefined &&
                       (typeof value === 'object' || typeof value === 'function') &&
                       typeof value.then === 'function';
            }
            """)
    }

    // MARK: Source transform

    /// JavaScriptCore has no module system, so the documented entry contract
    /// `export default async function …` is desugared to a plain global
    /// assignment before evaluation. Only the first `export default` token
    /// is replaced — enough for an entry file; a stray occurrence inside a
    /// string literal would produce a syntax error that surfaces like any
    /// other script error.
    static func preprocess(_ source: String) -> String {
        let pattern = #"\bexport\s+default\b"#
        guard let range = source.range(of: pattern, options: .regularExpression) else {
            return source
        }
        return source.replacingCharacters(in: range, with: "globalThis.run =")
    }

    // MARK: Result decoding

    /// Whether `value` is a promise — an object or function with a callable
    /// `then`. Checked in JS via the installed helper rather than by poking
    /// at properties from Swift.
    private static func isThenable(_ value: JSValue, in context: JSContext) -> Bool {
        guard let check = context.objectForKeyedSubscript("__invoque_isThenable"),
              check.isObject else { return false }
        return check.call(withArguments: [value])?.toBool() ?? false
    }

    /// Maps the script's return value to `JSResult.Output`. Anything that is
    /// not an object with `items` or `title` is `void` — a bare string return
    /// is not a title, keeping the contract unambiguous.
    static func decode(_ value: JSValue?) -> JSResult.Output {
        guard let value, value.isObject,
              let object = value.toObject() as? [String: Any] else {
            return .void
        }
        if let rawItems = object["items"] as? [Any] {
            return .items(rawItems.compactMap(Self.decodeItem))
        }
        if let title = object["title"] as? String {
            return .title(title)
        }
        return .void
    }

    /// One `{title, subtitle, icon, arg}` row. Returns nil without a string
    /// title — malformed items are dropped, not fatal.
    private static func decodeItem(_ object: Any) -> JSResult.Item? {
        guard let dictionary = object as? [String: Any],
              let title = dictionary["title"] as? String else { return nil }
        return JSResult.Item(title: title,
                             subtitle: dictionary["subtitle"] as? String,
                             icon: dictionary["icon"] as? String,
                             arg: stringValue(dictionary["arg"]))
    }

    /// `arg` arrives as a string in well-formed output, but a number is
    /// coerced rather than dropping the item.
    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Single-shot wrapper for the awaited continuation: the JS queue and the
/// off-queue timeout race to complete it, and exactly one of them wins.
private final class CompletionBox {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSResult, Never>?

    init(continuation: CheckedContinuation<JSResult, Never>) {
        self.continuation = continuation
    }

    func complete(_ result: JSResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
