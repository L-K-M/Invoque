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

    /// Commands whose last invocation timed out while the script was still
    /// running. A stuck script never releases its queue thread or context,
    /// so a filter command that hangs re-run per keystroke would strand a
    /// thread and a JSContext heap per keystroke — once a command hangs it
    /// is refused for the rest of the session rather than leaking again.
    private let stuckLock = NSLock()
    private var stuckCommands = Set<String>()

    init(defaultTimeout: TimeInterval = 10) {
        self.defaultTimeout = defaultTimeout
    }

    private func markStuck(_ name: String) {
        stuckLock.lock()
        stuckCommands.insert(name)
        stuckLock.unlock()
    }

    private func isStuck(_ name: String) -> Bool {
        stuckLock.lock()
        defer { stuckLock.unlock() }
        return stuckCommands.contains(name)
    }

    // MARK: Running

    /// Runs `run(args, ctx)` from the command's entry script and awaits the
    /// promise it returns. Returns a `JSResult` carrying the decoded output,
    /// the captured log lines, and any script-level failure — never throws:
    /// every failure mode (including an unreadable entry file) arrives as
    /// `JSResult.error`, so one channel carries all of them.
    func run(command: Command, args: [String] = [], timeout: TimeInterval? = nil) async -> JSResult {
        // A command whose script previously hung is refused outright: its
        // abandoned queue thread and context never come back, and filter
        // mode would strand another pair per keystroke.
        guard !isStuck(command.name) else {
            return JSResult(output: .void, logs: [], error: .timedOut)
        }
        let logs = CommandLog()
        return await withCheckedContinuation { (continuation: CheckedContinuation<JSResult, Never>) in
            let box = CompletionBox(continuation: continuation)
            let fetches = FetchTaskRegistry()
            let effectiveTimeout = timeout ?? defaultTimeout

            // The timer deliberately runs off the JS queue: it must still
            // fire when the queue is stuck inside synchronous JavaScript.
            // A DispatchWorkItem so a fast completion can cancel it instead
            // of every keystroke leaving a pending timer around.
            let timeoutWork = DispatchWorkItem { [weak self] in
                let won = box.complete(JSResult(output: .void, logs: logs.snapshot, error: .timedOut))
                if won { self?.markStuck(command.name) }
            }
            box.onWin = { [weak timeoutWork] in
                // Weak: box → onWin → timeoutWork → box would otherwise be a
                // retain cycle leaking per invocation. asyncAfter retains
                // the item while it is pending, so the weak ref is valid
                // exactly when cancellation matters.
                timeoutWork?.cancel()
                // Pending fetches would otherwise complete into an
                // abandoned context, running dead-world promise callbacks.
                fetches.cancelAll()
            }

            let queue = DispatchQueue(label: "com.invoque.js.\(command.name)")
            queue.async {
                self.execute(command: command, args: args,
                             logs: logs, box: box, queue: queue, fetches: fetches)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout, execute: timeoutWork)
        }
    }

    // MARK: Execution (JS queue)

    /// The whole invocation, top to bottom, on `queue` — including the
    /// entry-file read, so a filter re-run per keystroke never does disk
    /// I/O on a caller-owned (possibly main) thread. An unreadable entry
    /// arrives as `.exception` rather than a throw: a throw cannot cross
    /// the continuation boundary anyway.
    private func execute(command: Command, args: [String],
                         logs: CommandLog, box: CompletionBox, queue: DispatchQueue,
                         fetches: FetchTaskRegistry) {
        guard let data = try? Data(contentsOf: command.entryURL),
              let source = String(data: data, encoding: .utf8) else {
            box.complete(JSResult(output: .void, logs: logs.snapshot,
                                  error: .exception("could not read entry file at \(command.entryURL.path)")))
            return
        }

        guard let context = JSContext() else {
            box.complete(JSResult(output: .void, logs: logs.snapshot,
                                  error: .exception("JavaScriptCore context creation failed")))
            return
        }

        // evaluateScript doesn't throw; uncaught exceptions land here. The
        // raw JSValue is captured — `toString()` inside the handler would
        // render a thrown object as "[object Object]".
        var exceptionValue: JSValue?
        context.exceptionHandler = { _, value in
            exceptionValue = value
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
                                                  callbackQueue: queue, fetches: fetches)

        _ = context.evaluateScript(Self.preprocess(source))
        if let exceptionValue {
            let message = Self.describeReason(exceptionValue, in: context,
                                              fallback: "Unknown JavaScript exception")
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
        if let exceptionValue {
            let message = Self.describeReason(exceptionValue, in: context,
                                              fallback: "Unknown JavaScript exception")
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
            let message: String
            if let context = JSContext.current() {
                message = Self.describeReason(value, in: context,
                                              fallback: "Promise rejected without a reason")
            } else {
                message = value?.toString() ?? "Promise rejected without a reason"
            }
            box.complete(JSResult(output: .void, logs: logs.snapshot, error: .rejected(message)))
        }
        context.globalObject.setValue(fulfill, forProperty: "__invoque_fulfill")
        context.globalObject.setValue(reject, forProperty: "__invoque_reject")
        context.globalObject.setValue(returned, forProperty: "__invoque_pending")
        _ = context.evaluateScript("__invoque_pending.then(__invoque_fulfill, __invoque_reject)")
        if let exceptionValue {
            let message = Self.describeReason(exceptionValue, in: context,
                                              fallback: "Unknown JavaScript exception")
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

    /// Renders a thrown or rejected value for an error message. `toString()`
    /// on a plain object yields "[object Object]", so objects are
    /// JSON-stringified and `Error` instances unwrap to their `message`.
    private static func describeReason(_ value: JSValue?, in context: JSContext,
                                       fallback: String) -> String {
        guard let value, !value.isUndefined, !value.isNull else { return fallback }
        context.globalObject.setValue(value, forProperty: "__invoque_reason_arg")
        let rendered = context.evaluateScript("""
            (function (v) {
                if (v instanceof Error) return v.message || String(v);
                if (typeof v === 'object') {
                    try { return JSON.stringify(v); } catch (e) { return String(v); }
                }
                return String(v);
            })(__invoque_reason_arg)
            """)?.toString()
        context.globalObject.deleteProperty("__invoque_reason_arg")
        return rendered ?? value.toString()
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
    /// assignment before evaluation.
    ///
    /// Only the first `export default` that introduces a callable is
    /// rewritten — i.e. one followed by `function`, `async function`, `(`
    /// (arrow function) or a bare identifier (function reference). An
    /// `export default` in a different position — including inside a string
    /// literal — is left alone, and a remaining untransformed token fails to
    /// parse as an ordinary script error rather than silently corrupting
    /// string contents.
    static func preprocess(_ source: String) -> String {
        let pattern = #"\bexport\s+default\b"#
        var searchStart = source.startIndex
        while let range = source.range(of: pattern, options: .regularExpression,
                                       range: searchStart..<source.endIndex) {
            let rest = source[range.upperBound...]
                .drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
            if rest.hasPrefix("function") || rest.hasPrefix("async") || rest.hasPrefix("(")
               || rest.first?.isLetter == true || rest.first == "_" || rest.first == "$" {
                return source.replacingCharacters(in: range, with: "globalThis.run =")
            }
            searchStart = range.upperBound
        }
        return source
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

    /// Invoked once, only by the winning `complete` — used to cancel the
    /// losing side's pending work (the timeout timer, in-flight fetches).
    /// Assigned before any completion can run.
    var onWin: (() -> Void)?

    init(continuation: CheckedContinuation<JSResult, Never>) {
        self.continuation = continuation
    }

    /// Returns true when this call delivered the result — false when the
    /// race was already lost, so callers can act only on the win.
    @discardableResult
    func complete(_ result: JSResult) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let onWin = continuation != nil ? self.onWin : nil
        lock.unlock()
        if continuation != nil { onWin?() }
        continuation?.resume(returning: result)
        return continuation != nil
    }
}
