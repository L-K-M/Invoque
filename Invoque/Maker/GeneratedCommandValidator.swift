import Foundation
import JavaScriptCore

/// Checks a parsed generation before it can become a saved command:
///
/// 1. `command.json` decodes as `CommandManifest` and passes the same
///    structural checks `validate(in:)` makes (schema, slug name, known
///    permissions, entry path stays inside the directory) — without needing
///    the files on disk.
/// 2. The entry file named by the manifest was actually generated.
/// 3. The entry source parses as JavaScript — compiled, never run.
/// 4. Permission cross-check: every `invoque.<module>` the script touches is
///    covered by `manifest.permissions`, and every declared permission is
///    actually used — the Maker never silently grants (PLAN §4.3).
///
/// Everything is reported as actionable issue strings (shown in the Maker
/// view and feedable back to the model), not thrown — a draft with issues is
/// still inspectable.
enum GeneratedCommandValidator {

    /// The outcome of validating one generation. `manifest` is nil only when
    /// `command.json` couldn't be decoded at all — every other failure lands
    /// in `issues` alongside it.
    struct Outcome: Equatable {
        let manifest: CommandManifest?
        /// Problems in human-readable, actionable form. Empty = clean.
        let issues: [String]

        var isValid: Bool { issues.isEmpty }
    }

    static func validate(_ generation: GeneratedCommand) -> Outcome {
        var issues: [String] = []

        guard let manifest = decodeManifest(generation.manifestJSON, issues: &issues) else {
            return Outcome(manifest: nil, issues: issues)
        }
        validateStructure(manifest, issues: &issues)
        validateEntryPresent(generation, manifest: manifest, issues: &issues)
        validateJavaScript(generation.entrySource, name: generation.entryName,
                           issues: &issues)
        validateEntryPoint(generation.entrySource, name: generation.entryName,
                           issues: &issues)
        validatePermissions(generation: generation, manifest: manifest,
                            issues: &issues)
        return Outcome(manifest: manifest, issues: issues)
    }

    // MARK: Manifest

    private static func decodeManifest(_ json: String,
                                       issues: inout [String]) -> CommandManifest? {
        do {
            return try JSONDecoder().decode(CommandManifest.self,
                                            from: Data(json.utf8))
        } catch {
            issues.append("command.json isn't a valid manifest: \(error.localizedDescription)")
            return nil
        }
    }

    private static func validateStructure(_ manifest: CommandManifest,
                                          issues: inout [String]) {
        do {
            try manifest.validateStructure()
        } catch {
            issues.append("manifest: \(error.localizedDescription)")
        }
    }

    /// The manifest's `entry` must name a file the generation produced —
    /// usually `main.js`, or whatever single `.js` the parser resolved.
    private static func validateEntryPresent(_ generation: GeneratedCommand,
                                             manifest: CommandManifest,
                                             issues: inout [String]) {
        guard generation.files[manifest.entry] == nil else { return }
        issues.append(
            "manifest entry '\(manifest.entry)' wasn't generated — "
            + "the files are: \(generation.files.keys.sorted().joined(separator: ", "))")
    }

    // MARK: JavaScript syntax

    /// Compiles — but never runs — the entry source. `new Function(src)`
    /// parses `src` without executing a statement of it, so a syntax error
    /// surfaces as an exception while top-level side effects (or an
    /// accidental infinite loop) can't run at validation time. The source is
    /// preprocessed first so the `export default` contract parses.
    private static func validateJavaScript(_ source: String, name: String,
                                           issues: inout [String]) {
        guard let context = JSContext() else {
            issues.append("JavaScriptCore unavailable — couldn't syntax-check \(name)")
            return
        }
        context.globalObject.setValue(JSRuntime.preprocess(source),
                                      forProperty: "__invoque_check_source")
        _ = context.evaluateScript("new Function(__invoque_check_source)")
        if let exception = context.exception {
            issues.append("\(name) doesn't parse: \(exception.toString() ?? "syntax error")")
        }
    }

    /// The runtime needs a callable `run`: a top-level `function run`,
    /// `const run = …`, or the `export default` sugar. Checked on the masked
    /// source so a comment mentioning `run` can't satisfy it — a draft with
    /// no entry point would only fail later as `.missingEntryPoint`.
    private static func validateEntryPoint(_ source: String, name: String,
                                           issues: inout [String]) {
        let masked = maskedSource(source)
        let found = masked.firstMatch(of: #/\bexport\s+default\b/#) != nil
            || masked.firstMatch(of: #/\bfunction\s+run\b/#) != nil
            || masked.range(of: "\\brun\\s*=", options: .regularExpression) != nil
        if !found {
            issues.append(
                "\(name) defines no entry point — the runtime needs "
                + "`export default async function run(args)` or `async function run(args)`")
        }
    }

    // MARK: Permission cross-check

    /// `invoque.<module>` → the permission that must back it. Modules not in
    /// this table and not in `alwaysAvailable` are unknown — likely a
    /// hallucinated API, which is itself an issue.
    private static let modulePermissions: [String: CommandManifest.Permission] = [
        "fetch": .network,
        "fs": .files,
        "shell": .shell,
    ]

    /// Modules the bridge installs only as throwing stubs — declaring the
    /// permission makes `typeof invoque.paste` truthy but every method fails
    /// at runtime. A script that calls one can never work, so it's an issue
    /// outright rather than a permission requirement (PLAN §4.2 stubs).
    private static let stubModules: Set<String> = ["paste", "apps"]

    /// Modules injected regardless of permissions: `args`, `log`, `notify`,
    /// `open`, `storage` (see InvoqueBridge). `notify` is always present —
    /// the `notification` permission exists in the schema but gates nothing.
    private static let alwaysAvailable: Set<String> = [
        "args", "log", "notify", "open", "storage",
    ]

    /// The permission a declared `notification` maps back to for the
    /// unused-permission check — `invoque.notify` is its only consumer.
    private static let notificationModule = "notify"

    private static func validatePermissions(generation: GeneratedCommand,
                                            manifest: CommandManifest,
                                            issues: inout [String]) {
        let source = maskedSource(generation.entrySource)
        let declared = manifest.grantedPermissions
        var required = Set<CommandManifest.Permission>()
        var usedModules = Set<String>()

        for module in moduleTokens(in: source).sorted() {
            if alwaysAvailable.contains(module) {
                usedModules.insert(module)
            } else if module == "clipboard" {
                checkClipboard(in: source, declared: declared,
                               required: &required, used: &usedModules,
                               issues: &issues)
            } else if stubModules.contains(module) {
                // Counted as "used" so a matching declaration isn't also
                // flagged unused — one clear issue beats two contradictory.
                usedModules.insert(module)
                issues.append(
                    "script uses 'invoque.\(module)', which is only a stub — "
                    + "every method throws 'not implemented yet' at runtime; remove it")
            } else if let permission = modulePermissions[module] {
                required.insert(permission)
                usedModules.insert(module)
            } else {
                issues.append(
                    "script uses 'invoque.\(module)', which isn't a known module — "
                    + "the available modules are: \(alwaysAvailable.sorted().joined(separator: ", ")), "
                    + "clipboard, and the permission-gated fetch/fs/shell")
            }
        }

        for permission in required.subtracting(declared).sorted(by: permissionOrder) {
            issues.append(
                "script uses invoque.\(moduleName(for: permission)) but \"\(permission.rawValue)\" "
                + "isn't in manifest.permissions — add it or remove the call")
        }

        for permission in declared.sorted(by: permissionOrder)
        where !isUsed(permission, required: required, usedModules: usedModules) {
            issues.append(
                "manifest declares \"\(permission.rawValue)\" but the script never uses "
                + "\(moduleName(for: permission)) — drop it or use it")
        }

        // JSRuntime withholds side-effect modules from filter-mode commands
        // even when declared — a filter that needs them can never work.
        if manifest.mode == .filter {
            for permission: CommandManifest.Permission in [.shell, .paste]
            where required.contains(permission) || declared.contains(permission) {
                issues.append(
                    "filter-mode commands can't use \"\(permission.rawValue)\" — "
                    + "the runtime withholds it (a per-keystroke side effect is a footgun)")
            }
        }
    }

    /// The source with strings and comments blanked — an `invoque.fetch`
    /// mention inside a comment or literal is not a permission requirement.
    /// Character count is preserved so regex offsets stay meaningful.
    /// Built by concatenation rather than in-place replacement: the ranges
    /// index `source`, and a mutated copy's indices aren't guaranteed to
    /// stay interchangeable once copy-on-write gives it new storage.
    private static func maskedSource(_ source: String) -> String {
        let opaque = JSRuntime.opaqueRanges(in: source)
        guard !opaque.isEmpty else { return source }
        var masked = ""
        masked.reserveCapacity(source.count)
        var cursor = source.startIndex
        for range in opaque {
            masked += source[cursor..<range.lowerBound]
            masked += String(repeating: " ", count: range.count)
            cursor = range.upperBound
        }
        masked += source[cursor...]
        return masked
    }

    /// Distinct `invoque.<token>`/`ctx.<token>` module names referenced by
    /// the script — `run(args, ctx)` receives the same object, so both names
    /// are the API surface.
    private static func moduleTokens(in source: String) -> Set<String> {
        var tokens = Set<String>()
        for match in source.matches(
            of: #/\b(?:invoque|ctx)\.([A-Za-z_$][A-Za-z0-9_$]*)/#) {
            tokens.insert(String(match.1))
        }
        return tokens
    }

    /// `invoque.clipboard` gates per-method: `.read` needs `clipboard.read`,
    /// `.write` needs `clipboard.write`. A bare `invoque.clipboard` (aliased,
    /// passed around) requires at least one clipboard permission. `used`
    /// records `"clipboard.read"`/`"clipboard.write"` per method and
    /// `"clipboard"` for the bare form, so the unused-permission check can
    /// be exact.
    private static func checkClipboard(in source: String,
                                       declared: Set<CommandManifest.Permission>,
                                       required: inout Set<CommandManifest.Permission>,
                                       used: inout Set<String>,
                                       issues: inout [String]) {
        var sawMethod = false
        for match in source.matches(
            of: #/\b(?:invoque|ctx)\.clipboard\.([A-Za-z_$][A-Za-z0-9_$]*)/#) {
            sawMethod = true
            switch match.1 {
            case "read":
                required.insert(.clipboardRead)
                used.insert("clipboard.read")
            case "write":
                required.insert(.clipboardWrite)
                used.insert("clipboard.write")
            default:
                issues.append(
                    "script calls 'invoque.clipboard.\(match.1)' — "
                    + "the only clipboard methods are read() and write()")
            }
        }
        if !sawMethod {
            // `invoque.clipboard` referenced without a known method —
            // aliased or passed around. It needs *some* clipboard grant;
            // either declared one counts as exercised.
            used.insert("clipboard")
            if declared.isDisjoint(with: [.clipboardRead, .clipboardWrite]) {
                issues.append(
                    "script touches invoque.clipboard — declare \"clipboard.read\" "
                    + "or \"clipboard.write\" in manifest.permissions")
            }
        }
    }

    /// Deterministic order for issue lists.
    private static func permissionOrder(_ lhs: CommandManifest.Permission,
                                        _ rhs: CommandManifest.Permission) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether a declared permission is exercised by the script.
    private static func isUsed(_ permission: CommandManifest.Permission,
                               required: Set<CommandManifest.Permission>,
                               usedModules: Set<String>) -> Bool {
        if required.contains(permission) { return true }
        switch permission {
        case .clipboardRead:
            return usedModules.contains("clipboard.read")
                || usedModules.contains("clipboard")
        case .clipboardWrite:
            return usedModules.contains("clipboard.write")
                || usedModules.contains("clipboard")
        case .notification:
            // `notify` is always installed — declaring `notification` is only
            // meaningful as documentation that the command notifies.
            return usedModules.contains(notificationModule)
        case .network: return usedModules.contains("fetch")
        case .files: return usedModules.contains("fs")
        case .apps: return usedModules.contains("apps")
        case .paste: return usedModules.contains("paste")
        case .shell: return usedModules.contains("shell")
        }
    }

    /// The module name a permission guards, for issue text.
    private static func moduleName(for permission: CommandManifest.Permission) -> String {
        switch permission {
        case .clipboardRead: return "clipboard.read"
        case .clipboardWrite: return "clipboard.write"
        case .network: return "fetch"
        case .files: return "fs"
        case .apps: return "apps"
        case .paste: return "paste"
        case .shell: return "shell"
        case .notification: return "notify"
        }
    }
}
