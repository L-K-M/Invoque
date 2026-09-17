import AppKit
import Foundation
import JavaScriptCore

/// Assembles the `invoque` global for a command's JSContext.
///
/// This is the capability boundary for generated (untrusted) code: only the
/// modules backed by the manifest's permissions are installed — undeclared
/// modules are absent entirely (`invoque.fetch` is `undefined` without
/// `network`), not merely stubbed. Methods are `@convention(block)` closures
/// on plain JS objects so the exposed surface can be tailored per manifest.
///
/// Installed blocks never capture the JSContext — that would retain it via
/// the very global object that owns the blocks. Anything needing the context
/// inside a callback goes through `JSContext.current()`.
enum InvoqueBridge {

    /// Serializes `invoque.storage` reads and writes across all invocations
    /// — see `installStorage`.
    private static let storageQueue = DispatchQueue(label: "com.invoque.storage")

    /// Installs `invoque` on `context`'s global object and returns it so the
    /// caller can also pass it as `ctx` to `run(args, ctx)`.
    ///
    /// `permissions` must already be mode-filtered by the caller (JSRuntime
    /// strips side-effect modules for filter-mode commands). `callbackQueue`
    /// is the invocation's JS queue: async completions like `fetch` hop onto
    /// it before touching JSValues, because a JSContext may only be used
    /// from one thread at a time. `fetches` tracks in-flight URLSession
    /// tasks so the runtime can cancel them when the invocation ends.
    @discardableResult
    static func install(in context: JSContext,
                        command: Command,
                        args: [String],
                        permissions: Set<CommandManifest.Permission>,
                        logs: CommandLog,
                        callbackQueue: DispatchQueue,
                        fetches: FetchTaskRegistry) -> JSValue? {
        guard let invoque = JSValue(newObjectIn: context) else { return nil }

        invoque.setValue(args, forProperty: "args")
        installUtilities(on: invoque, logs: logs)
        installStorage(on: invoque, context: context, dataDirectory: command.dataDirectory)

        if permissions.contains(.clipboardRead) || permissions.contains(.clipboardWrite) {
            installClipboard(on: invoque, context: context, permissions: permissions)
        }
        if permissions.contains(.network) {
            installFetch(on: invoque, context: context, callbackQueue: callbackQueue,
                         fetches: fetches)
        }
        if permissions.contains(.files) {
            installFileSystem(on: invoque, context: context, dataDirectory: command.dataDirectory)
        }
        if permissions.contains(.shell) {
            installShell(on: invoque, context: context)
        }
        // Declared but unimplemented in this milestone: objects exist so
        // `typeof invoque.paste` answers truthfully, but every method throws
        // "not implemented yet".
        if permissions.contains(.paste) {
            installStub(named: "paste", methods: ["text"], on: invoque, context: context)
        }
        if permissions.contains(.apps) {
            installStub(named: "apps", methods: ["list", "launch"], on: invoque, context: context)
        }
        // `notification` needs no module of its own: `notify` is always
        // present (and currently a log sink — see installUtilities).

        context.globalObject.setValue(invoque, forProperty: "invoque")
        return invoque
    }

    // MARK: Always-on modules

    /// `args`, `log`, `notify`, `open` — no permission required.
    private static func installUtilities(on invoque: JSValue, logs: CommandLog) {
        let log: @convention(block) () -> Void = {
            logs.append("[log] \(joinedArguments())")
        }
        invoque.setValue(log, forProperty: "log")

        // TODO(PLAN §4.2): real user notifications — UNUserNotificationCenter
        // needs the app's delegate wiring, so v1 sinks notify into the log.
        let notify: @convention(block) () -> Void = {
            logs.append("[notify] \(joinedArguments())")
        }
        invoque.setValue(notify, forProperty: "notify")

        // Deliberately web-only: an always-on, permission-free open must not
        // turn every generated command into an app launcher. Local files and
        // apps get a dedicated `apps` capability (currently a stub).
        let open: @convention(block) (String) -> Bool = { target in
            guard let url = URL(string: target),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return false
            }
            return NSWorkspace.shared.open(url)
        }
        invoque.setValue(open, forProperty: "open")
    }

    /// Per-command key-value store at `<command>/data/storage.json`. The file
    /// (and `data/`) is created lazily on first write — never merely because
    /// a command ran.
    private static func installStorage(on invoque: JSValue, context: JSContext, dataDirectory: URL) {
        guard let storage = JSValue(newObjectIn: context) else { return }

        let fileURL = dataDirectory.appendingPathComponent("storage.json")
        /// nil until first access.
        var cache: [String: Any]?

        func load() -> [String: Any] {
            if let cache { return cache }
            var loaded: [String: Any] = [:]
            if let data = try? Data(contentsOf: fileURL),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dictionary = object as? [String: Any] {
                loaded = dictionary
            }
            cache = loaded
            return loaded
        }

        func persist() {
            guard let cache,
                  JSONSerialization.isValidJSONObject(cache),
                  let data = try? JSONSerialization.data(withJSONObject: cache) else { return }
            do {
                try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // Best-effort: persistence failures surface only as a lost
                // write, so they are logged rather than thrown into JS.
                NSLog("Invoque: storage persist failed: \(error)")
            }
        }

        // All storage I/O runs on a shared serial queue: the read-modify-
        // write in set/delete must be atomic across invocations, or two
        // concurrently running commands clobber each other's keys (each
        // holds its own `cache`, so last-writer-wins would drop keys).
        let get: @convention(block) (String) -> JSValue? = { key in
            storageQueue.sync {
                guard let value = load()[key], let context = JSContext.current() else { return nil }
                return JSValue(object: value, in: context)
            }
        }
        let set: @convention(block) (String, JSValue) -> Void = { key, value in
            guard let object = value.toObject(),
                  JSONSerialization.isValidJSONObject(["value": object]) else {
                throwError("invoque.storage.set: value must be JSON-serializable")
                return
            }
            storageQueue.sync {
                var stored = load()
                stored[key] = object
                cache = stored
                persist()
            }
        }
        let delete: @convention(block) (String) -> Void = { key in
            storageQueue.sync {
                var stored = load()
                stored.removeValue(forKey: key)
                cache = stored
                persist()
            }
        }
        storage.setValue(get, forProperty: "get")
        storage.setValue(set, forProperty: "set")
        storage.setValue(delete, forProperty: "delete")
        invoque.setValue(storage, forProperty: "storage")
    }

    // MARK: clipboard.read / clipboard.write

    /// Each method is installed only when its own permission is declared, so
    /// a read-only command genuinely has no `invoque.clipboard.write`.
    private static func installClipboard(on invoque: JSValue, context: JSContext,
                                         permissions: Set<CommandManifest.Permission>) {
        guard let clipboard = JSValue(newObjectIn: context) else { return }
        if permissions.contains(.clipboardRead) {
            let read: @convention(block) () -> String? = {
                NSPasteboard.general.string(forType: .string)
            }
            clipboard.setValue(read, forProperty: "read")
        }
        if permissions.contains(.clipboardWrite) {
            let write: @convention(block) (String) -> Void = { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            clipboard.setValue(write, forProperty: "write")
        }
        invoque.setValue(clipboard, forProperty: "clipboard")
    }

    // MARK: network

    /// `invoque.fetch(url, options?) -> Promise<{ok, status, body}>`.
    ///
    /// Implemented as a native callback function `__invoque_fetch` plus a JS
    /// shim that wraps it in a Promise — JSC cannot synthesize a native
    /// promise, so the promise lives in JS and the resolve/reject functions
    /// are handed to the native side. The body crosses as a string; JS uses
    /// `JSON.parse(body)` for JSON, keeping the bridge trivially small.
    private static func installFetch(on invoque: JSValue, context: JSContext,
                                     callbackQueue: DispatchQueue, fetches: FetchTaskRegistry) {
        let fetchImpl: @convention(block) (String, String, JSValue, JSValue) -> Void = { urlString, optionsJSON, resolve, reject in
            // Scheme allowlist: `file://` would turn the network permission
            // into arbitrary filesystem reads, and non-HTTP schemes can hand
            // requests to handlers outside URLSession.
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                _ = reject.call(withArguments: ["invoque.fetch: URL must be http(s): '\(urlString)'"])
                return
            }
            var request = URLRequest(url: url)
            if let data = optionsJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let options = object as? [String: Any] {
                if let method = options["method"] as? String {
                    request.httpMethod = method
                }
                if let headers = options["headers"] as? [String: String] {
                    for (name, value) in headers {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                }
                if let body = options["body"] as? String {
                    request.httpBody = body.data(using: .utf8)
                }
            }
            // The task is registered so the runtime can cancel it when the
            // invocation completes or times out — a completion that fires
            // afterward would call JSValues whose context was abandoned.
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                // JSValues are single-threaded: the resolve must run back on
                // the invocation's JS queue.
                callbackQueue.async {
                    if let error {
                        _ = reject.call(withArguments: ["invoque.fetch: \(error.localizedDescription)"])
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    _ = resolve.call(withArguments: [[
                        "ok": (200..<300).contains(status),
                        "status": status,
                        "body": body,
                    ]])
                }
            }
            fetches.add(task)
            task.resume()
        }
        context.globalObject.setValue(fetchImpl, forProperty: "__invoque_fetch")

        let shim = context.evaluateScript("""
            (function (url, options) {
                return new Promise(function (resolve, reject) {
                    __invoque_fetch(String(url), JSON.stringify(options || {}), resolve, reject);
                });
            })
            """)
        if let shim, !shim.isUndefined {
            invoque.setValue(shim, forProperty: "fetch")
        }
    }

    // MARK: files

    /// `invoque.fs` scoped strictly to the command's `data/` directory.
    /// Paths are resolved against that base and `..`/symlink escapes are
    /// refused — this module is the untrusted-code boundary, so a command
    /// must not be able to reach the rest of the disk through it.
    private static func installFileSystem(on invoque: JSValue, context: JSContext, dataDirectory: URL) {
        guard let fs = JSValue(newObjectIn: context) else { return }

        let base = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        func resolve(_ path: String) -> URL? {
            let resolved = base.appendingPathComponent(path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else {
                return nil
            }
            return resolved
        }

        let read: @convention(block) (String) -> String? = { path in
            guard let url = resolve(path) else {
                throwError("invoque.fs: '\(path)' escapes the command's data directory")
                return nil
            }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        let write: @convention(block) (String, String) -> Bool = { path, contents in
            guard let url = resolve(path) else {
                throwError("invoque.fs: '\(path)' escapes the command's data directory")
                return false
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        let list: @convention(block) (String) -> [String]? = { path in
            guard let url = resolve(path) else {
                throwError("invoque.fs: '\(path)' escapes the command's data directory")
                return nil
            }
            return try? FileManager.default.contentsOfDirectory(atPath: url.path)
        }
        fs.setValue(read, forProperty: "read")
        fs.setValue(write, forProperty: "write")
        fs.setValue(list, forProperty: "list")
        invoque.setValue(fs, forProperty: "fs")
    }

    // MARK: shell

    /// `invoque.shell.run("…")` → `{code, stdout, stderr}` via `/bin/sh -c`.
    /// Synchronous by design: it runs on the invocation's JS queue (never the
    /// main thread) and the invocation timeout covers runaway commands.
    private static func installShell(on invoque: JSValue, context: JSContext) {
        guard let shell = JSValue(newObjectIn: context) else { return }

        let run: @convention(block) (String) -> [String: Any] = { commandString in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", commandString]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
            } catch {
                return ["code": -1, "stdout": "", "stderr": "invoque.shell: \(error.localizedDescription)"]
            }
            // readabilityHandlers accumulate output as it arrives — a
            // backgrounded grandchild inherits the pipes and holds them open
            // past the shell's exit, so a wait-for-EOF read would hang
            // forever (and a bounded one would lose partial output). EOF is
            // signaled by an empty availableData chunk.
            let drain = PipeDrain()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                drain.appendStdout(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                drain.appendStderr(handle.availableData)
            }
            process.waitUntilExit()
            drain.waitUntilDrained(timeout: 5)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let (stdout, stderr) = drain.output
            return [
                "code": Int(process.terminationStatus),
                "stdout": String(decoding: stdout, as: UTF8.self),
                "stderr": String(decoding: stderr, as: UTF8.self),
            ]
        }
        shell.setValue(run, forProperty: "run")
        invoque.setValue(shell, forProperty: "shell")
    }

    // MARK: Stubs

    /// Declared-but-unimplemented modules: present as objects whose methods
    /// throw when called, so scripts fail loudly instead of silently.
    private static func installStub(named name: String, methods: [String],
                                    on invoque: JSValue, context: JSContext) {
        guard let module = JSValue(newObjectIn: context) else { return }
        for method in methods {
            let block: @convention(block) () -> Void = {
                throwError("invoque.\(name).\(method) is not implemented yet")
            }
            module.setValue(block, forProperty: method)
        }
        invoque.setValue(module, forProperty: name)
    }

    // MARK: Helpers

    /// Throws `message` as a JS exception from inside a native callback:
    /// assigning `context.exception` makes JSC raise it when the call returns
    /// to JavaScript.
    static func throwError(_ message: String) {
        guard let context = JSContext.current() else { return }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    /// Joins the current JS call's arguments the way console.log prints them.
    static func joinedArguments() -> String {
        let arguments = JSContext.currentArguments() ?? []
        return arguments
            .map { ($0 as? JSValue)?.toString() ?? String(describing: $0) }
            .joined(separator: " ")
    }
}

/// Accumulates a process's stdout/stderr from `readabilityHandler`
/// callbacks and reports EOF (empty chunk) per pipe. `waitUntilDrained`
/// returns at both EOFs or the deadline — a backgrounded grandchild
/// inheriting the pipes means EOF may never come, but partial output is
/// still returned.
private final class PipeDrain {

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEOF = false
    private var stderrEOF = false

    func appendStdout(_ chunk: Data) {
        lock.lock()
        chunk.isEmpty ? (stdoutEOF = true) : stdout.append(chunk)
        lock.unlock()
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        chunk.isEmpty ? (stderrEOF = true) : stderr.append(chunk)
        lock.unlock()
    }

    /// Polls until both pipes report EOF or `timeout` elapses.
    func waitUntilDrained(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = stdoutEOF && stderrEOF
            lock.unlock()
            if done { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    var output: (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

/// Per-invocation registry of in-flight `invoque.fetch` tasks. The runtime
/// cancels them all when the invocation completes or times out, so a late
/// completion never calls resolve/reject JSValues in an abandoned context.
final class FetchTaskRegistry {

    private let lock = NSLock()
    private var tasks: [URLSessionTask] = []

    func add(_ task: URLSessionTask) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let pending = tasks
        tasks = []
        lock.unlock()
        pending.forEach { $0.cancel() }
    }
}
