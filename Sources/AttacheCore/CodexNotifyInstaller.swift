import Foundation

/// Pure, testable editing of Codex's `~/.codex/config.toml` `notify` array so
/// Attaché can add an immediacy channel for Codex turn status, mirroring what
/// `ClaudeHookInstaller` does for Claude Code's `settings.json`. Codex invokes
/// the `notify` program on turn events (`agent-turn-complete`); this places
/// Attaché's own notify program at the head of that array and CHAINS, never
/// clobbers, any notify program that was already configured.
///
/// Chaining uses the `--previous-notify` convention already present in the
/// user's real config: the previous notify command is JSON-encoded and passed
/// as the flag's value, and Attaché's program execs it (with the original
/// payload appended) after forwarding the event. Uninstall restores that
/// recorded previous array exactly, or deletes the key when there was none.
///
/// File IO lives in the app layer (`CodexNotifySetup`); this stays pure and
/// operates on TOML content strings. It preserves the rest of the file: only
/// the `notify` assignment is rewritten. It fails closed (throws `.malformed`)
/// rather than write into a `notify` entry it cannot safely parse.
public enum CodexNotifyInstaller {
    public enum Failure: Error, Equatable {
        /// A `notify` assignment exists but is not a parseable array of strings
        /// (unterminated bracket, non-array value, mixed element types). We
        /// never rewrite such a file.
        case malformed
    }

    /// The flag Attaché uses to carry the chained previous notify command,
    /// matching the convention already in the user's config.
    public static let previousFlag = "--previous-notify"

    /// The `notify` array currently defined at the root of `toml`, or nil if
    /// absent. Throws `.malformed` if a root `notify` assignment exists but is
    /// not a well-formed array of strings.
    public static func currentNotify(in toml: String) throws -> [String]? {
        let lines = toml.components(separatedBy: "\n")
        guard try notifySpan(in: lines) != nil else { return nil }
        // Span detection proved the assignment is present, array-formed, and
        // terminated; MinimalTOML gives the comment-stripped, unescaped value.
        guard let array = extractStringArray(MinimalTOML.parse(toml)["notify"]) else {
            throw Failure.malformed
        }
        return array
    }

    /// True when Attaché's managed program is already the head of the notify
    /// array.
    public static func isInstalled(_ toml: String, managedProgramPath: String) throws -> Bool {
        (try currentNotify(in: toml))?.first == managedProgramPath
    }

    public struct InstallResult: Equatable {
        /// The rewritten config content (unchanged when already installed).
        public let toml: String
        /// The notify array captured before Attaché wrapped it (nil if there
        /// was none), which uninstall restores. When already installed, this
        /// reports the previous embedded in the existing entry.
        public let previousNotify: [String]?
        /// Whether `toml` differs from the input.
        public let changed: Bool

        public init(toml: String, previousNotify: [String]?, changed: Bool) {
            self.toml = toml
            self.previousNotify = previousNotify
            self.changed = changed
        }
    }

    /// Return `toml` with Attaché's managed program installed as the notify
    /// head, chaining any pre-existing notify command. Idempotent: if Attaché's
    /// program is already the head, the content is returned unchanged.
    public static func install(_ toml: String, managedProgramPath: String) throws -> InstallResult {
        let existing = try currentNotify(in: toml)
        if let existing, existing.first == managedProgramPath {
            return InstallResult(toml: toml, previousNotify: embeddedPrevious(in: existing), changed: false)
        }
        let previous = existing // may be nil (no notify configured yet)
        var array = [managedProgramPath]
        if let previous {
            array += [previousFlag, encodePrevious(previous)]
        }
        let updated = try setNotify(array, in: toml)
        return InstallResult(toml: updated, previousNotify: previous, changed: updated != toml)
    }

    /// Return `toml` with Attaché's managed entry removed: the recorded
    /// previous notify (embedded in the current entry) restored exactly, or the
    /// `notify` key deleted when there was no previous. Unchanged if the head is
    /// not Attaché's program (never touch a foreign entry).
    public static func remove(_ toml: String, managedProgramPath: String) throws -> String {
        guard let existing = try currentNotify(in: toml), existing.first == managedProgramPath else {
            return toml
        }
        if let previous = embeddedPrevious(in: existing) {
            return try setNotify(previous, in: toml)
        }
        return try deleteNotify(in: toml)
    }

    // MARK: - Chaining record

    static func embeddedPrevious(in array: [String]) -> [String]? {
        guard let index = array.firstIndex(of: previousFlag), index + 1 < array.count else { return nil }
        return decodePrevious(array[index + 1])
    }

    static func encodePrevious(_ array: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func decodePrevious(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    // MARK: - TOML value extraction

    static func extractStringArray(_ value: MinimalTOML.Value?) -> [String]? {
        guard case .array(let values)? = value else { return nil }
        var result: [String] = []
        for element in values {
            guard case .string(let string) = element else { return nil }
            result.append(string)
        }
        return result
    }

    // MARK: - Line-oriented span editing (preserves the rest of the file)

    struct NotifySpan {
        let startLine: Int
        let endLine: Int
    }

    /// Locate the root-scope `notify` assignment as an inclusive line range, or
    /// nil if there is none before the first table header. Throws `.malformed`
    /// when the value is not an array or the array bracket never closes.
    static func notifySpan(in lines: [String]) throws -> NotifySpan? {
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                // A table header: any `notify` past here is not the root key.
                return nil
            }
            if isNotifyAssignment(trimmed) {
                guard let equal = lines[index].firstIndex(of: "=") else { index += 1; continue }
                let rhs = String(lines[index][lines[index].index(after: equal)...])
                guard rhs.trimmingCharacters(in: .whitespaces).hasPrefix("[") else {
                    // notify present but not an array form: fail closed.
                    throw Failure.malformed
                }
                var depth = bracketDepthDelta(rhs)
                var end = index
                while depth > 0 {
                    end += 1
                    guard end < lines.count else { throw Failure.malformed } // unterminated array
                    depth += bracketDepthDelta(lines[end])
                }
                if depth < 0 { throw Failure.malformed }
                return NotifySpan(startLine: index, endLine: end)
            }
            index += 1
        }
        return nil
    }

    static func isNotifyAssignment(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("notify") else { return false }
        let after = trimmed.dropFirst("notify".count).drop(while: { $0 == " " || $0 == "\t" })
        return after.first == "="
    }

    /// Net bracket depth change contributed by one line, respecting TOML basic
    /// and literal strings, escapes, and `#` comments.
    static func bracketDepthDelta(_ line: String) -> Int {
        var depth = 0
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for character in line {
            if inBasic {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inBasic = false }
                continue
            }
            if inLiteral {
                if character == "'" { inLiteral = false }
                continue
            }
            switch character {
            case "#": return depth // comment runs to end of line
            case "\"": inBasic = true
            case "'": inLiteral = true
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// Replace the existing notify span with a single-line assignment, or
    /// insert one at root scope (before the first table header) when absent.
    static func setNotify(_ array: [String], in toml: String) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        let newLine = "notify = " + renderArray(array)
        if let span = try notifySpan(in: lines) {
            lines.replaceSubrange(span.startLine...span.endLine, with: [newLine])
            return lines.joined(separator: "\n")
        }
        // No existing notify: insert at root scope.
        if let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
            lines.insert(newLine, at: headerIndex)
        } else if lines.last == "" {
            // File ends with a trailing newline: keep it after our inserted line.
            lines.insert(newLine, at: lines.count - 1)
        } else {
            lines.append(newLine)
        }
        return lines.joined(separator: "\n")
    }

    static func deleteNotify(in toml: String) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let span = try notifySpan(in: lines) else { return toml }
        lines.removeSubrange(span.startLine...span.endLine)
        return lines.joined(separator: "\n")
    }

    static func renderArray(_ array: [String]) -> String {
        "[" + array.map(tomlBasicString).joined(separator: ", ") + "]"
    }

    static func tomlBasicString(_ string: String) -> String {
        var out = "\""
        for character in string {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        out += "\""
        return out
    }
}
