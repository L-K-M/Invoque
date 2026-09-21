import AppKit
import ApplicationServices
import CoreGraphics
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

    /// The most body `invoque.fetch` will hand to a command. The download
    /// task already spools to a temp file instead of memory; the cap
    /// governs what JS sees — a multi-GB or lying Content-Length response
    /// is rejected rather than buffered whole. Enforced in `fetchOutcome`
    /// once the download finishes: the spooled temp file is rejected
    /// before being read back, so an oversized body never crosses into JS
    /// memory, and the file is deleted when the handler returns. The
    /// transfer itself is bounded by the invocation timeout (`fetches`
    /// cancels on teardown); aborting the download mid-flight would take
    /// a `URLSessionDownloadDelegate` with per-task callback plumbing the
    /// completion-handler API doesn't have.
    static let maxFetchBytes = 20 * 1024 * 1024

    /// Fetch session with a redirect guard: the http(s) allowlist is applied
    /// to the initial URL, and this session re-applies it to every redirect
    /// target rather than trusting URLSession's default cross-scheme policy.
    private static let httpSession: URLSession = {
        // `.ephemeral`: `.default` would share the app's cookie storage and
        // URL cache, letting one command's fetch ride another's session —
        // exactly the cross-command isolation this boundary exists to keep.
        URLSession(configuration: .ephemeral,
                   delegate: HTTPRedirectGuard(),
                   delegateQueue: nil)
    }()

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
        if permissions.contains(.open) {
            installOpen(on: invoque)
        }
        if permissions.contains(.shell) {
            installShell(on: invoque, context: context)
        }
        if permissions.contains(.paste) {
            installPaste(on: invoque, context: context)
        }
        if permissions.contains(.apps) {
            installApps(on: invoque, context: context)
        }
        // `notification` needs no module of its own: `notify` is always
        // present (and currently a log sink — see installUtilities).

        context.globalObject.setValue(invoque, forProperty: "invoque")
        return invoque
    }

    // MARK: Always-on modules

    /// `args`, `log`, `notify` — no permission required. (`args` is set by
    /// the caller; `open` moved to the gated section — ambient http(s)
    /// open is an egress channel, not a utility.)
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
    }

    /// `invoque.open(url)` — gated on the `open` permission, not free:
    /// arbitrary http(s) URLs are a network-egress channel (query strings
    /// can carry read clipboard contents to a remote host), so it must be
    /// a declared capability like `network`, not an ambient one.
    /// Deliberately web-only — local files and apps get the dedicated `apps`
    /// capability instead.
    private static func installOpen(on invoque: JSValue) {
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

        // Always reads disk — a per-invocation cache goes stale the moment
        // another invocation writes, and persisting the stale snapshot would
        // silently drop the other invocation's keys.
        func load() -> [String: Any] {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return [:] }
            return dictionary
        }

        func persist(_ stored: [String: Any]) {
            guard JSONSerialization.isValidJSONObject(stored),
                  let data = try? JSONSerialization.data(withJSONObject: stored) else { return }
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
        // concurrently running commands clobber each other's keys.
        let get: @convention(block) (String) -> JSValue? = { key in
            // JSContext.current() is thread-local: inside storageQueue.sync
            // the block can run on the queue's worker thread under
            // contention, where it returns nil. Capture the context on the
            // JS thread, do disk I/O inside the serial queue, then build
            // the JSValue back on the JS thread.
            guard let context = JSContext.current() else { return nil }
            let stored = storageQueue.sync { load() }
            guard let value = stored[key] else { return nil }
            return JSValue(object: value, in: context)
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
                persist(stored)
            }
        }
        let delete: @convention(block) (String) -> Void = { key in
            storageQueue.sync {
                var stored = load()
                stored.removeValue(forKey: key)
                persist(stored)
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
                // Values cross JSON.stringify, so a numeric header arrives
                // as NSNumber — cast to [String: Any] and coerce, or one
                // numeric header would silently drop the entire set.
                if let headers = options["headers"] as? [String: Any] {
                    for (name, value) in headers {
                        if let string = value as? String {
                            request.setValue(string, forHTTPHeaderField: name)
                        } else if let number = value as? NSNumber {
                            request.setValue(number.stringValue, forHTTPHeaderField: name)
                        }
                    }
                }
                if let body = options["body"] as? String {
                    request.httpBody = body.data(using: .utf8)
                }
            }
            // A download task, not a data task: the body spools to a temp
            // file rather than accumulating in memory, and `fetchOutcome`
            // size-checks before the read — an oversized response is
            // rejected at `maxFetchBytes` instead of exhausting memory.
            // The file is deleted when this handler returns, so the read
            // happens here and only the capped string hops to the JS queue.
            // The task is registered so the runtime can cancel it when the
            // invocation completes or times out — a completion that fires
            // afterward would call JSValues whose context was abandoned.
            let task = Self.httpSession.downloadTask(with: request) { fileURL, response, error in
                switch Self.fetchOutcome(fileURL: fileURL, response: response, error: error) {
                case .failure(let message):
                    callbackQueue.async {
                        _ = reject.call(withArguments: [message])
                    }
                case .success(let status, let body):
                    callbackQueue.async {
                        _ = resolve.call(withArguments: [[
                            "ok": (200..<300).contains(status),
                            "status": status,
                            "body": body,
                        ]])
                    }
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

    /// The fetch verdict — `.failure` carries the full `invoque.fetch:`
    /// rejection message destined for the JS `reject`. A dedicated enum,
    /// not `Result`: `Result`'s failure must conform to `Error`, and the
    /// JS-facing payload is a plain message string.
    enum FetchOutcome {
        case success(status: Int, body: String)
        case failure(String)
    }

    /// Maps a completed download to the fetch result — extracted from the
    /// task callback so the policy (scheme re-check, size cap, decode) is
    /// unit-testable without a live server.
    static func fetchOutcome(fileURL: URL?, response: URLResponse?,
                             error: Error?) -> FetchOutcome {
        if let error {
            return .failure("invoque.fetch: \(error.localizedDescription)")
        }
        // Defense in depth: if a redirect slipped past the delegate onto a
        // non-http(s) URL, refuse the body.
        if let finalScheme = response?.url?.scheme?.lowercased(),
           finalScheme != "http", finalScheme != "https" {
            let target = response?.url?.absoluteString ?? ""
            return .failure("invoque.fetch: redirect left http(s): '\(target)'")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let fileURL,
              let values = try? fileURL.resourceValues(
                  forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return .failure("invoque.fetch: no readable body")
        }
        // A directory or pipe can report a size — or none at all, which
        // filesystems disagree on — so the type check comes first: a
        // non-regular file is an unreadable body either way, and on
        // older macOS Data(contentsOf:) could even hand its bytes back.
        guard values.isRegularFile else {
            return .failure("invoque.fetch: could not read body")
        }
        guard let size = values.fileSize else {
            return .failure("invoque.fetch: no readable body")
        }
        guard size <= maxFetchBytes else {
            return .failure("invoque.fetch: response exceeds the \(maxFetchBytes / 1024 / 1024) MB limit")
        }
        guard let raw = try? Data(contentsOf: fileURL) else {
            return .failure("invoque.fetch: could not read body")
        }
        let body = String(data: raw, encoding: .utf8) ?? ""
        return .success(status: status, body: body)
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

    // MARK: paste

    /// `invoque.paste.text(text)` — copies `text` onto the clipboard and
    /// posts ⌘V at the HID event tap so it lands in the app the user was
    /// working in. Two gates apply before this module even exists in JS:
    /// the manifest's `paste` permission and the risky-permission consent
    /// card. This layer adds the third: Accessibility trust, checked per
    /// call (and prompted lazily on first use) rather than at app launch.
    private static func installPaste(on invoque: JSValue, context: JSContext) {
        guard let paste = JSValue(newObjectIn: context) else { return }

        let text: @convention(block) (String) -> Bool = { contents in
            // `hasPrompted` is read *before* prompt() runs: it tells whether
            // the system dialog will actually appear this call — it only
            // shows once. On a repeat denial there's no dialog, so opening
            // the pane directly is the only prompt the user gets; on the
            // first denial the dialog (with its own Settings button) is
            // already up and stacking the pane on top of it is worse.
            let promptedBefore = AccessibilityAuthorizer.hasPrompted
            guard AccessibilityAuthorizer.isTrusted || AccessibilityAuthorizer.prompt() else {
                if promptedBefore {
                    AccessibilityAuthorizer.openSystemSettings()
                }
                throwError("invoque.paste.text: Accessibility access required — grant Invoque in System Settings → Privacy & Security → Accessibility")
                return false
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(contents, forType: .string)

            // The keystroke lands wherever the system's focus is. The panel
            // is nonactivating, so `frontmostApplication` is still the app
            // the user was working in; activating it gives it a real key
            // window — and resigns our panel, which hides it — before the
            // synthetic ⌘V posts. Without this the keystroke could land in
            // the launcher's own search field. The pid compare is the
            // documented-safe identity check for NSRunningApplication.
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let frontmost,
               frontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
                frontmost.activate()
                Self.waitForFocus(on: frontmost.processIdentifier)
            }

            // kVK_ANSI_V. Posting down and up as a spread pair — some apps
            // debounce same-timestamp pairs.
            let vKey: CGKeyCode = 9
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
                throwError("invoque.paste.text: could not synthesize the ⌘V keystroke")
                return false
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            keyUp.post(tap: .cghidEventTap)
            // The pasted text stays on the clipboard — that's the point for
            // the transform-clipboard commands this module exists for.
            return true
        }
        paste.setValue(text, forProperty: "text")
        invoque.setValue(paste, forProperty: "paste")
    }

    // MARK: apps

    /// `invoque.apps.list()` → `[{name, path, bundleID}]` and
    /// `invoque.apps.launch(target)` → Bool. `list` rescans the app folders
    /// on every call — a few hundred bundle reads on the JS queue — so the
    /// answer is what's installed *now*, not what the launcher's own cache
    /// last saw. The scan itself is `AppCatalog`, shared with `AppSource`.
    private static func installApps(on invoque: JSValue, context: JSContext) {
        guard let apps = JSValue(newObjectIn: context) else { return }

        let list: @convention(block) () -> [[String: Any]] = {
            AppCatalog.installedApps().map { entry in
                var dictionary: [String: Any] = ["name": entry.name, "path": entry.path]
                if let bundleID = entry.bundleID {
                    dictionary["bundleID"] = bundleID
                }
                return dictionary
            }
        }

        // Resolution is strict — path, then bundle id, then exact display
        // name (AppCatalog.resolve) — because launching is a side effect:
        // a fuzzy guess that opens the wrong app is worse than an error the
        // script can report. Path targets are additionally confined to the
        // catalog itself: `apps` covers installed apps, not arbitrary .app
        // bundles elsewhere on disk.
        let launch: @convention(block) (String) -> Bool = { target in
            guard let url = AppCatalog.resolve(target, in: AppCatalog.installedApps()) else {
                throwError("invoque.apps.launch: no app matching '\(target)'")
                return false
            }
            return NSWorkspace.shared.open(url)
        }

        apps.setValue(list, forProperty: "list")
        apps.setValue(launch, forProperty: "launch")
        invoque.setValue(apps, forProperty: "apps")
    }

    // MARK: Helpers

    /// Bounded wait until `pid` owns the system-wide AX focus — the same
    /// truth the synthesized keystroke obeys. `frontmostApplication` can't
    /// signal this (the nonactivating panel means it already equals the
    /// target before `activate()`), but the AX focus does move — and this
    /// module already holds AX trust, so the query is available. Bounded at
    /// 500 ms: a stuck activation degrades to the old fixed-sleep behavior,
    /// never a hang.
    private static func waitForFocus(on pid: pid_t) {
        let systemWide = AXUIElementCreateSystemWide()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &focused) == .success,
               let application = focused {
                // Safe: the focused-application attribute always yields an
                // AXUIElement (same idiom as Zap's WindowEnumerator).
                var focusedPID: pid_t = 0
                AXUIElementGetPid((application as! AXUIElement), &focusedPID)
                if focusedPID == pid { return }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

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

/// Refuses to follow a 3xx redirect to a non-http(s) URL: the fetch
/// allowlist is enforced on the initial URL, and this keeps a `Location`
/// header from walking it outside the sandbox boundary.
private final class HTTPRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(scheme == "http" || scheme == "https" ? request : nil)
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
final class FetchTaskRegistry: @unchecked Sendable {

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
