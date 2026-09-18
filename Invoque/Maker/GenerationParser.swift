import Foundation

/// The files a generation produced: the manifest JSON plus the entry source
/// plus any extra files, keyed by command-relative paths.
///
/// The entry file is usually `main.js`; when the model emits a single `.js`
/// file under another name (and declares it as `entry`), that file is the
/// entry instead.
struct GeneratedCommand: Equatable {
    /// Raw `command.json` contents — kept as text; decoding and validation
    /// are `GeneratedCommandValidator`'s job.
    let manifestJSON: String
    /// Entry file name relative to the command directory, e.g. `"main.js"`.
    let entryName: String
    /// The entry file's JavaScript source.
    let entrySource: String
    /// Additional files (name → contents) the command ships, e.g.
    /// `"lib/util.js"`. Validated to stay inside the command directory.
    let extraFiles: [String: String]

    /// All files the writer will emit, entry included.
    var files: [String: String] {
        var all = extraFiles
        all["command.json"] = manifestJSON
        all[entryName] = entrySource
        return all
    }
}

/// Turns raw LLM output into a `GeneratedCommand`.
///
/// Two wire formats are accepted (the system prompt demands the first; the
/// second is the habit every model falls back to):
///
/// 1. Delimiter blocks — `--- name ---` headers on their own line:
///    `--- command.json ---`, `--- main.js ---`, `--- lib/util.js ---`.
///    Preamble/prose before the first header is ignored.
/// 2. Markdown fences — ```` ```json ```` → `command.json`,
///    ```` ```js ````/```` ```javascript ```` → `main.js`. A fence may carry
///    an explicit name via ```` ```lang:path ```` or ```` ```lang path ````.
///
/// Strict on the two required halves: exactly one manifest and exactly one
/// entry file — duplicates or absences are typed errors, not silent picks.
enum GenerationParser {

    enum Failure: Error, Equatable, LocalizedError {
        /// Nothing usable at all — empty or whitespace-only output.
        case empty
        /// No `command.json`/`json` block found.
        case missingManifest
        /// More than one manifest block.
        case multipleManifests
        /// No entry file found (`main.js`, a lone `.js` file, or a `js` fence).
        case missingEntryFile
        /// Two or more candidate entry files and no `main.js` to disambiguate.
        case multipleEntryFiles([String])
        /// The entry block (`main.js`) appeared more than once.
        case duplicateEntry
        /// A filename was explicitly rejected: escapes the directory or is
        /// not a plausible relative path.
        case invalidFileName(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "the model returned an empty response"
            case .missingManifest:
                return "no command.json found — expected a `--- command.json ---` block or a ```json fence"
            case .multipleManifests:
                return "the response contains more than one command.json block"
            case .missingEntryFile:
                return "no entry file found — expected a `--- main.js ---` block or a ```javascript fence"
            case .multipleEntryFiles(let names):
                return "multiple candidate entry files (\(names.sorted().joined(separator: ", "))) — name the entry main.js"
            case .duplicateEntry:
                return "main.js was emitted more than once — merge the blocks into a single file"
            case .invalidFileName(let name):
                return "invalid file name '\(name)' — files must be relative paths inside the command directory"
            }
        }
    }

    // MARK: Parse

    /// A filename as it may appear between `---` markers: a plausible
    /// relative path. Explicitly excludes `..` segments and absolute paths —
    /// a header that fails this check is treated as prose, not a block.
    private static let headerNamePattern = "\\A[A-Za-z0-9_.][A-Za-z0-9_./-]*\\z"

    static func parse(_ output: String) throws -> GeneratedCommand {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.empty
        }

        let lines = normalized.components(separatedBy: "\n")
        // A stray `--- name ---`-shaped prose line (say `--- 1 ---`) must
        // not force delimiter mode for a fence-formatted response: when the
        // delimited pass can't produce the required pair, retry as fences
        // before failing.
        if lines.contains(where: { delimiterName(in: $0) != nil }) {
            do {
                return try assemble(try collectDelimited(lines))
            } catch let delimitedError as Failure {
                switch delimitedError {
                case .missingManifest, .missingEntryFile:
                    // The header-like line was probably prose — retry as
                    // fences. If that fails too, report whichever pass got
                    // further: a fenced manifest with a delimited entry
                    // should say "missing entry", not "missing manifest"
                    // (a real `--- command.json ---` header that lacks an
                    // entry still surfaces the delimited missingEntryFile).
                    do {
                        return try assemble(try collectFenced(lines))
                    } catch let fencedError as Failure {
                        if case .missingEntryFile = fencedError {
                            throw fencedError
                        }
                        throw delimitedError
                    }
                default:
                    throw delimitedError
                }
            }
        }
        return try assemble(try collectFenced(lines))
    }

    /// Builds the `GeneratedCommand` from the collected name → contents map:
    /// exactly one `command.json`, an entry (`main.js`, or the sole `.js`
    /// file), everything else an extra file.
    private static func assemble(_ files: [String: String]) throws -> GeneratedCommand {
        guard let manifest = files["command.json"] else {
            throw Failure.missingManifest
        }
        let jsFiles = files.keys.filter { $0.hasSuffix(".js") }
        let entryName: String
        if files["main.js"] != nil {
            entryName = "main.js"
        } else if jsFiles.count == 1, let only = jsFiles.first {
            entryName = only
        } else if jsFiles.count > 1 {
            throw Failure.multipleEntryFiles(jsFiles)
        } else {
            throw Failure.missingEntryFile
        }
        guard let entrySource = files[entryName] else {
            throw Failure.missingEntryFile
        }
        var extras = files
        extras.removeValue(forKey: "command.json")
        extras.removeValue(forKey: entryName)
        return GeneratedCommand(manifestJSON: manifest, entryName: entryName,
                                entrySource: entrySource, extraFiles: extras)
    }

    // MARK: Block collection

    /// The name inside a `--- name ---` line, or nil when the line is not a
    /// block header (horizontal rules, prose, `--- name` without a closing
    /// marker, implausible names like `../../etc/passwd`).
    private static func delimiterName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("---"), trimmed.hasSuffix("---"),
              trimmed.count > 6 else { return nil }
        let name = trimmed.dropFirst(3).dropLast(3)
            .trimmingCharacters(in: .whitespaces)
        return isPlausibleFileName(name) ? name : nil
    }

    /// `command.json`, `main.js`, `lib/util.js` pass; `..` segments,
    /// hidden/dotfile segments, absolute paths, backslashes and empty
    /// names don't.
    private static func isPlausibleFileName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name.range(of: headerNamePattern, options: .regularExpression) != nil,
              !name.contains("\\"),
              !name.hasPrefix("/"),
              !name.hasPrefix("."),
              !name.hasSuffix("/"),
              !name.contains("//"),
              !name.contains("/."),
              !name.components(separatedBy: "/").contains("..") else {
            return false
        }
        return true
    }

    /// Delimiter mode: everything between `--- name ---` headers is file
    /// content; text before the first header is prose and ignored.
    private static func collectDelimited(_ lines: [String]) throws -> [String: String] {
        var files: [String: String] = [:]
        var currentName: String?
        var currentLines: [String] = []
        var duplicateManifest = false
        var duplicateEntry = false

        func flush() {
            guard let name = currentName else { return }
            // A second header for a required slot is ambiguous output, not
            // "last wins" — the model contradicted itself.
            if files[name] != nil {
                if name == "command.json" { duplicateManifest = true }
                if name == "main.js" { duplicateEntry = true }
            }
            var content = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            // Models often fence the payload inside a `--- name ---` block;
            // unwrap a single enclosing fence so the file isn't polluted
            // with ``` markers. Code files only — a .md/.txt payload could
            // legitimately begin and end with fence lines.
            let codeFile = name.hasSuffix(".js") || name.hasSuffix(".json")
            let block = content.components(separatedBy: "\n")
            if codeFile, block.count >= 2,
               block.first?.trimmingCharacters(in: .whitespaces)
                   .hasPrefix("```") == true,
               let last = block.last?.trimmingCharacters(in: .whitespaces),
               last.count >= 3, last.allSatisfy({ $0 == "`" }) {
                content = block.dropFirst().dropLast().joined(separator: "\n")
            }
            files[name] = content
        }

        for line in lines {
            if let name = delimiterName(in: line) {
                flush()
                currentName = name
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()

        if duplicateManifest { throw Failure.multipleManifests }
        if duplicateEntry { throw Failure.duplicateEntry }
        return files
    }

    // MARK: Markdown fences

    /// Fence mode: ```` ```lang ```` opens a block, ```` ``` ```` closes it.
    /// The info string may carry a filename (`js:lib/util.js` or
    /// `json command.json`); language alone maps `json` → `command.json`
    /// and `js`/`javascript` → `main.js`. Unrecognized or untagged fences
    /// are ignored (they're prose examples, not files).
    private static func collectFenced(_ lines: [String]) throws -> [String: String] {
        var files: [String: String] = [:]
        var inFence = false
        var currentName: String?
        var currentLines: [String] = []
        var duplicateManifest = false
        var duplicateEntry = false

        func flush() {
            guard let name = currentName else { return }
            if name == "command.json", files[name] != nil { duplicateManifest = true }
            if name == "main.js", files[name] != nil { duplicateEntry = true }
            files[name] = currentLines.joined(separator: "\n")
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inFence {
                guard trimmed.hasPrefix("```") else { continue }
                // Four-plus-backtick fences are a common model habit —
                // strip however many open the line.
                let info = String(trimmed.dropFirst(
                    trimmed.prefix(while: { $0 == "`" }).count))
                    .trimmingCharacters(in: .whitespaces)
                // A fence that closes on the same line (```main.js``` …) is
                // an inline code span in prose, not a block opener.
                if info.contains("```") { continue }
                inFence = true
                currentName = try fileName(forInfo: info)
                currentLines = []
            } else if trimmed.allSatisfy({ $0 == "`" }), trimmed.count >= 3 {
                flush()
                inFence = false
                currentName = nil
            } else {
                currentLines.append(line)
            }
        }
        // An unclosed trailing fence still yields its file — a truncated
        // response is the model's most common failure, and the downstream
        // JS-syntax check will flag the broken half.
        if inFence { flush() }

        if duplicateManifest { throw Failure.multipleManifests }
        if duplicateEntry { throw Failure.duplicateEntry }
        return files
    }

    /// Maps a fence info string to a file name, or nil for fences that don't
    /// name a file (plain ```` ``` ````, or languages we can't place like
    /// ```` ```python ````). Throws on an explicitly invalid `lang:path`.
    private static func fileName(forInfo info: String) throws -> String? {
        guard !info.isEmpty else { return nil }
        // `lang:path` or `lang path` — the tag is the first token, an
        // optional explicit name follows a `:` or whitespace.
        let language: String
        var explicitName: String?
        if let colon = info.firstIndex(of: ":") {
            language = String(info[..<colon])
                .trimmingCharacters(in: .whitespaces)
            explicitName = String(info[info.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        } else if let space = info.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            language = String(info[..<space])
                .trimmingCharacters(in: .whitespaces)
            explicitName = String(info[space...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            language = info
        }

        if let name = explicitName, !name.isEmpty {
            // An explicit name is a deliberate file claim — a bad one is an
            // error, not silence (unlike an unplaceable language tag).
            guard isPlausibleFileName(name) else {
                throw Failure.invalidFileName(name)
            }
            return name
        }

        switch language.lowercased() {
        case "json": return "command.json"
        case "js", "javascript": return "main.js"
        default: return nil
        }
    }
}
