import Foundation

/// JSON value with JS semantics: numbers are doubles, objects keep insertion order,
/// `stringify` produces the same bytes as `JSON.stringify` for the values the SDK writes.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Boxes Foundation / Swift values (String, Bool, numbers, arrays, dictionaries, NSNull).
    public static func from(_ any: Any?) -> JSONValue {
        guard let any else { return .null }
        if let v = any as? JSONValue { return v }
        if let v = any as? JSONObject { return .object(v) }
        if any is NSNull { return .null }
        if let n = any as? NSNumber, !(any is String) {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let v = any as? Bool { return .bool(v) }
        if let v = any as? Int { return .number(Double(v)) }
        if let v = any as? Int64 { return .number(Double(v)) }
        if let v = any as? Double { return .number(v) }
        if let v = any as? String { return .string(v) }
        if let v = any as? Substring { return .string(String(v)) }
        if let v = any as? [Any?] { return .array(v.map { from($0) }) }
        if let v = any as? [String: Any?] {
            var o = JSONObject()
            for k in v.keys.sorted() { o[k] = from(v[k] ?? nil) }
            return .object(o)
        }
        if let v = any as? Date { return .number((v.timeIntervalSince1970 * 1000).rounded()) }
        return .string(String(describing: any))
    }

    /// Unboxes to Foundation types (for bridges such as Flutter).
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 9.0e15 ? Int64(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundationValue }
        case .object(let o):
            var d: [String: Any] = [:]
            o.forEach { d[$0] = $1.foundationValue }
            return d
        }
    }

    public func stringify() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSONValue.formatNumber(n)
        case .string(let s): JSONValue.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            var first = true
            o.forEach { k, v in
                if !first { out += "," }
                first = false
                JSONValue.quote(k, into: &out)
                out += ":"
                v.write(into: &out)
            }
            out += "}"
        }
    }

    static func formatNumber(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == n.rounded(), abs(n) < 1e21 {
            if abs(n) < 9.2e18 { return String(Int64(n)) }
            return String(format: "%.0f", n)
        }
        return "\(n)"
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    public static func parse(_ text: String?) -> JSONValue? {
        guard let text, !text.isEmpty else { return nil }
        var p = Parser(Array(text.utf16))
        guard let v = p.value() else { return nil }
        p.ws()
        return p.i == p.s.count ? v : nil
    }

    private struct Parser {
        let s: [UInt16]
        var i = 0
        init(_ s: [UInt16]) { self.s = s }

        mutating func ws() {
            while i < s.count, s[i] == 0x20 || s[i] == 0x0A || s[i] == 0x0D || s[i] == 0x09 { i += 1 }
        }

        mutating func value() -> JSONValue? {
            ws()
            guard i < s.count else { return nil }
            switch s[i] {
            case 0x7B: return object()
            case 0x5B: return array()
            case 0x22: return string().map { .string($0) }
            case 0x74: return literal("true", .bool(true))
            case 0x66: return literal("false", .bool(false))
            case 0x6E: return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ v: JSONValue) -> JSONValue? {
            let w = Array(word.utf16)
            guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func object() -> JSONValue? {
            i += 1
            var o = JSONObject()
            ws()
            if i < s.count, s[i] == 0x7D { i += 1; return .object(o) }
            while i < s.count {
                ws()
                guard i < s.count, s[i] == 0x22, let k = string() else { return nil }
                ws()
                guard i < s.count, s[i] == 0x3A else { return nil }
                i += 1
                guard let v = value() else { return nil }
                o[k] = v
                ws()
                guard i < s.count else { return nil }
                if s[i] == 0x2C { i += 1; continue }
                if s[i] == 0x7D { i += 1; return .object(o) }
                return nil
            }
            return nil
        }

        mutating func array() -> JSONValue? {
            i += 1
            var a: [JSONValue] = []
            ws()
            if i < s.count, s[i] == 0x5D { i += 1; return .array(a) }
            while i < s.count {
                guard let v = value() else { return nil }
                a.append(v)
                ws()
                guard i < s.count else { return nil }
                if s[i] == 0x2C { i += 1; continue }
                if s[i] == 0x5D { i += 1; return .array(a) }
                return nil
            }
            return nil
        }

        mutating func string() -> String? {
            i += 1
            var units: [UInt16] = []
            while i < s.count {
                let c = s[i]
                if c == 0x22 { i += 1; return String(decoding: units, as: UTF16.self) }
                if c == 0x5C {
                    guard i + 1 < s.count else { return nil }
                    let e = s[i + 1]
                    i += 2
                    switch e {
                    case 0x6E: units.append(0x0A)
                    case 0x72: units.append(0x0D)
                    case 0x74: units.append(0x09)
                    case 0x62: units.append(0x08)
                    case 0x66: units.append(0x0C)
                    case 0x75:
                        guard i + 4 <= s.count, let h = UInt16(String(decoding: s[i..<i + 4], as: UTF16.self), radix: 16) else { return nil }
                        units.append(h)
                        i += 4
                    default: units.append(e)
                    }
                } else {
                    units.append(c)
                    i += 1
                }
            }
            return nil
        }

        mutating func number() -> JSONValue? {
            let start = i
            while i < s.count, (s[i] >= 0x30 && s[i] <= 0x39) || s[i] == 0x2D || s[i] == 0x2B || s[i] == 0x2E || s[i] == 0x65 || s[i] == 0x45 { i += 1 }
            guard i > start, let d = Double(String(decoding: s[start..<i], as: UTF16.self)) else { return nil }
            return .number(d)
        }
    }
}

/// Insertion-ordered JSON object; assigning an existing key keeps its position (JS object semantics).
public struct JSONObject: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var values: [String: JSONValue] = [:]

    public init() {}
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (k, v) in elements { self[k] = v }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func forEach(_ body: (String, JSONValue) -> Void) {
        for k in keys { if let v = values[k] { body(k, v) } }
    }

    public mutating func merge(_ other: JSONObject) {
        other.forEach { self[$0] = $1 }
    }

    public static func from(_ dict: [String: Any?]?) -> JSONObject? {
        guard let dict else { return nil }
        return JSONValue.from(dict).objectValue
    }

    public func stringify() -> String { JSONValue.object(self).stringify() }
}
