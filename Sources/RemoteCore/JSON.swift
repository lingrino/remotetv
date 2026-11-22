/// A JSON value for tvctl's `--json` output. Written by hand rather than through
/// Foundation so the output is one line with its keys in the order the code lists them
/// ("ok" first), which is what both a person and a parser want to see.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([Member])

    public struct Member: Sendable, Equatable {
        public let key: String
        public let value: JSON
    }

    /// A string, or null.
    public static func optional(_ s: String?) -> JSON { s.map(JSON.string) ?? .null }

    /// Seconds (a position, a length), to the millisecond; null when unknown.
    public static func seconds(_ d: Double?) -> JSON {
        guard let d, d.isFinite else { return .null }
        return .number((d * 1000).rounded() / 1000)
    }

    var members: [Member] {
        if case .object(let m) = self { return m }
        return []
    }

    public subscript(key: String) -> JSON? { members.first { $0.key == key }?.value }

    /// The value on one line.
    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .number(let d):
            if !d.isFinite {
                out += "null"
            } else if d == d.rounded(), abs(d) < 1e15 {
                out += String(Int(d))
            } else {
                out += "\(d)"
            }
        case .string(let s): JSON.quote(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += "," }
                JSON.quote(m.key, to: &out)
                out += ":"
                m.value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func quote(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
                ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(elements.map { Member(key: $0.0, value: $0.1) }) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(nilLiteral: ()) { self = .null }
}
