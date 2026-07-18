import Foundation

/// A deliberately minimal TOML reader: just enough to pull `[mcp_servers.<name>]`
/// tables out of a Codex `config.toml`. It handles tables, dotted table headers,
/// basic and literal strings (with escapes), string/array/inline-table values,
/// booleans, integers, floats, and `#` comments. It does NOT attempt full TOML
/// (no multiline basic strings, no datetimes, no array-of-tables semantics), and
/// it never throws: an unparseable statement is skipped.
public enum MinimalTOML {
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case integer(Int)
        case double(Double)
        case boolean(Bool)
        case array([Value])
        case table([String: Value])
    }

    /// Parse whole TOML content into a nested table.
    public static func parse(_ text: String) -> [String: Value] {
        var root: [String: Value] = [:]
        var currentPath: [String] = []
        for statement in statements(from: text) {
            if statement.hasPrefix("[") {
                let path = splitDotted(tableHeaderInner(statement))
                guard !path.isEmpty else { continue }
                currentPath = path
                ensureTable(at: path, in: &root)
            } else if let eq = topLevelEqualIndex(statement) {
                let keyPart = String(statement[statement.startIndex..<eq])
                    .trimmingCharacters(in: .whitespaces)
                let valuePart = String(statement[statement.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                guard let value = parseValue(valuePart) else { continue }
                let keyPath = splitDotted(keyPart)
                guard !keyPath.isEmpty else { continue }
                setValue(value, at: currentPath + keyPath, in: &root)
            }
        }
        return root
    }

    // MARK: Statement segmentation

    /// Split the text into logical statements, stripping comments and joining
    /// lines that are inside an unclosed array/inline-table. String contents
    /// (including `#`, `[`, `]`, `\n`) are respected.
    static func statements(from text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        var inBasic = false
        var inLiteral = false
        var escaped = false
        var inComment = false
        var depth = 0

        func endLine() {
            if depth == 0 {
                result.append(buffer)
                buffer = ""
            } else {
                buffer.append(" ")
            }
        }

        for character in text {
            if inComment {
                if character == "\n" {
                    inComment = false
                    endLine()
                }
                continue
            }
            if inBasic {
                buffer.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasic = false
                }
                continue
            }
            if inLiteral {
                buffer.append(character)
                if character == "'" { inLiteral = false }
                continue
            }
            switch character {
            case "#":
                inComment = true
            case "\"":
                inBasic = true
                buffer.append(character)
            case "'":
                inLiteral = true
                buffer.append(character)
            case "[", "{":
                depth += 1
                buffer.append(character)
            case "]", "}":
                if depth > 0 { depth -= 1 }
                buffer.append(character)
            case "\n":
                endLine()
            default:
                buffer.append(character)
            }
        }
        result.append(buffer)
        return result
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func tableHeaderInner(_ statement: String) -> String {
        var trimmed = statement.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix("[") { trimmed.removeFirst() }
        while trimmed.hasSuffix("]") { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Value parsing

    static func parseValue(_ raw: String) -> Value? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        switch first {
        case "\"":
            return .string(unescapeBasic(trimmed))
        case "'":
            return .string(unescapeLiteral(trimmed))
        case "[":
            return parseArray(trimmed)
        case "{":
            return parseInlineTable(trimmed)
        default:
            if trimmed == "true" { return .boolean(true) }
            if trimmed == "false" { return .boolean(false) }
            if let integer = Int(trimmed) { return .integer(integer) }
            if let double = Double(trimmed) { return .double(double) }
            // A bare, unquoted token: keep it as a string rather than dropping it.
            return .string(trimmed)
        }
    }

    private static func parseArray(_ string: String) -> Value {
        guard let open = string.firstIndex(of: "["),
              let close = string.lastIndex(of: "]"),
              open < close else {
            return .array([])
        }
        let inner = String(string[string.index(after: open)..<close])
        let values = splitTopLevel(inner, on: ",").compactMap { part -> Value? in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : parseValue(trimmed)
        }
        return .array(values)
    }

    private static func parseInlineTable(_ string: String) -> Value {
        guard let open = string.firstIndex(of: "{"),
              let close = string.lastIndex(of: "}"),
              open < close else {
            return .table([:])
        }
        let inner = String(string[string.index(after: open)..<close])
        var table: [String: Value] = [:]
        for pair in splitTopLevel(inner, on: ",") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let eq = topLevelEqualIndex(trimmed) else { continue }
            let keyPart = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let valuePart = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let keyPath = splitDotted(keyPart)
            guard !keyPath.isEmpty, let value = parseValue(valuePart) else { continue }
            setValue(value, at: keyPath, in: &table)
        }
        return .table(table)
    }

    private static func unescapeBasic(_ string: String) -> String {
        let characters = Array(string)
        var result = ""
        var index = 1 // skip opening quote
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u":
                    let hex = String(characters[(index + 1)..<min(index + 5, characters.count)])
                    if let scalar = unicodeScalar(hex) { result.append(Character(scalar)); index += 4 }
                case "U":
                    let hex = String(characters[(index + 1)..<min(index + 9, characters.count)])
                    if let scalar = unicodeScalar(hex) { result.append(Character(scalar)); index += 8 }
                default:
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break // closing quote
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    private static func unicodeScalar(_ hex: String) -> Unicode.Scalar? {
        guard let code = UInt32(hex, radix: 16) else { return nil }
        return Unicode.Scalar(code)
    }

    private static func unescapeLiteral(_ string: String) -> String {
        let characters = Array(string)
        var result = ""
        var index = 1 // skip opening quote
        while index < characters.count, characters[index] != "'" {
            result.append(characters[index])
            index += 1
        }
        return result
    }

    // MARK: Scanning helpers

    /// Split a string on `separator` at the top level only: separators inside
    /// strings, arrays, or inline tables are left alone.
    static func splitTopLevel(_ string: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inBasic = false
        var inLiteral = false
        var escaped = false
        var depth = 0
        for character in string {
            if inBasic {
                current.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inBasic = false }
                continue
            }
            if inLiteral {
                current.append(character)
                if character == "'" { inLiteral = false }
                continue
            }
            switch character {
            case "\"":
                inBasic = true
                current.append(character)
            case "'":
                inLiteral = true
                current.append(character)
            case "[", "{":
                depth += 1
                current.append(character)
            case "]", "}":
                if depth > 0 { depth -= 1 }
                current.append(character)
            case separator where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// The index of the first top-level `=`, or nil.
    static func topLevelEqualIndex(_ string: String) -> String.Index? {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        var depth = 0
        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            if inBasic {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inBasic = false }
            } else if inLiteral {
                if character == "'" { inLiteral = false }
            } else {
                switch character {
                case "\"": inBasic = true
                case "'": inLiteral = true
                case "[", "{": depth += 1
                case "]", "}": if depth > 0 { depth -= 1 }
                case "=": if depth == 0 { return index }
                default: break
                }
            }
            index = string.index(after: index)
        }
        return nil
    }

    /// Split a dotted key path, unquoting quoted segments.
    static func splitDotted(_ string: String) -> [String] {
        splitTopLevel(string, on: ".").compactMap { segment -> String? in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("\"") { return unescapeBasic(trimmed) }
            if trimmed.hasPrefix("'") { return unescapeLiteral(trimmed) }
            return trimmed
        }
    }

    // MARK: Tree assembly

    static func setValue(_ value: Value, at path: [String], in table: inout [String: Value]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            table[first] = value
            return
        }
        var child: [String: Value]
        if case .table(let existing)? = table[first] { child = existing } else { child = [:] }
        setValue(value, at: Array(path.dropFirst()), in: &child)
        table[first] = .table(child)
    }

    static func ensureTable(at path: [String], in table: inout [String: Value]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            if case .table? = table[first] { return }
            if table[first] == nil { table[first] = .table([:]) }
            return
        }
        var child: [String: Value]
        if case .table(let existing)? = table[first] { child = existing } else { child = [:] }
        ensureTable(at: Array(path.dropFirst()), in: &child)
        table[first] = .table(child)
    }
}
