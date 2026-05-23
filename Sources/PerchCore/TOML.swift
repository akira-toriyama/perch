// Hand-rolled TOML *subset* parser. Ported from stroke / facet so
// perch can keep zero external SwiftPM dependencies (matches the
// reference repos' policy: Apple frameworks only).
//
// Supported subset:
//   - [section] / [sub.section]   (single dot levels)
//   - bare-key = value
//   - string  : "double-quoted", escaped with \\ \" \n \t
//   - int     : 123
//   - float   : 3.14
//   - bool    : true / false
//   - hex int : 0xFFFFFF        (handy for colors)
//   - array   : ["a", "b"]      (homogeneous string/int/bool/float)
//   - comments: # … to end of line
//
// Out of scope (deliberately):
//   - Inline tables {a=1,b=2}
//   - Arrays of tables [[rows]]
//   - Multi-line strings ("""…""")
//   - Date / time literals
//
// Out-of-range / unknown keys clamp silently per the
// "typo can't break the daemon" policy. The parser itself is
// permissive — semantic clamping happens in `PerchConfig.parse`.

import Foundation

public enum TOMLValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
}

public extension TOMLValue {
    var asString: String? { if case .string(let s) = self { return s }; return nil }
    var asInt: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    var asDouble: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }
    var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var asStringArray: [String]? {
        guard case .array(let xs) = self else { return nil }
        return xs.compactMap(\.asString)
    }
}

public enum TOML {
    public typealias Section = [String: TOMLValue]
    public typealias Document = [String: Section]

    /// Parse `src` into `[section: [key: value]]`. Unknown / malformed
    /// lines are silently skipped — the goal is "user's typo cannot
    /// break the daemon", not strict spec compliance.
    public static func parse(_ src: String) -> Document {
        var doc: Document = [:]
        var current = ""              // current section header
        doc[current] = [:]

        for rawLine in src.split(separator: "\n",
                                 omittingEmptySubsequences: false) {
            var line = String(rawLine)

            // Strip an unquoted `#` comment. A `#` inside a quoted
            // string is preserved.
            line = stripComment(line)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                current = header
                if doc[current] == nil { doc[current] = [:] }
                continue
            }

            // `key = value`
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
                .trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  let value = parseValue(raw) else { continue }
            doc[current]?[key] = value
        }
        return doc
    }

    // MARK: - Internals

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escape = false
        var out = ""
        for ch in line {
            if escape { escape = false; out.append(ch); continue }
            if ch == "\\" { escape = true; out.append(ch); continue }
            if ch == "\"" { inString.toggle(); out.append(ch); continue }
            if ch == "#" && !inString { return out }
            out.append(ch)
        }
        return out
    }

    private static func parseValue(_ raw: String) -> TOMLValue? {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            let body = String(raw.dropFirst().dropLast())
            return .string(unescape(body))
        }
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            let parts = splitArray(inner)
            var arr: [TOMLValue] = []
            for p in parts {
                let trimmed = p.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let v = parseValue(trimmed) { arr.append(v) }
            }
            return .array(arr)
        }
        if raw.hasPrefix("0x"), let i = Int(raw.dropFirst(2), radix: 16) {
            return .int(i)
        }
        if let i = Int(raw) { return .int(i) }
        if let d = Double(raw) { return .double(d) }
        return nil
    }

    /// Split a comma-separated array body, honouring quoted strings.
    /// Trailing commas (a TOML 1.0 feature) are tolerated.
    private static func splitArray(_ inner: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        var escape = false
        for ch in inner {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; current.append(ch); continue }
            if ch == "\"" { inString.toggle(); current.append(ch); continue }
            if ch == "," && !inString {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        while let ch = iter.next() {
            if ch == "\\", let next = iter.next() {
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(next)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
