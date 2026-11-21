/// OPACK, Apple's compact binary serialization used by every Companion message.
///
/// Tags (first byte of each object):
///   0x01 true · 0x02 false · 0x03 end of an open container · 0x04 null
///   0x05 UUID (16 bytes) · 0x06 date (8 bytes, little-endian double)
///   0x08–0x2F small integer 0…39 · 0x30/31/32/33 signed integer in 1/2/4/8 bytes (LE;
///   the TV sends -6714 as 0x31 C6 E5)
///   0x35 float32 · 0x36 float64 (LE)
///   0x40–0x60 UTF-8 string of 0…32 bytes · 0x61–0x64 string, length in 1–4 bytes
///   0x70–0x90 data of 0…32 bytes · 0x91–0x94 data, length in 1/2/4/8 bytes
///   0xA0–0xC0 reference to object #0…32 · 0xC1–0xC4 reference, index in 1–4 bytes
///   0xD0–0xDE array of 0…14 items · 0xDF array closed by 0x03
///   0xE0–0xEE dictionary of 0…14 pairs · 0xEF dictionary closed by 0x03
///
/// References point into the list of previously decoded objects other than booleans,
/// null, small integers and containers (strings — even empty ones — data, sized numbers,
/// UUIDs, dates), first occurrence only, as observed from Apple's encoder. The encoder
/// never emits references; the decoder resolves them.
public enum OPACK {
    public indirect enum Value: Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case data([UInt8])
        case uuid([UInt8])
        case date(Double)
        case array([Value])
        case dict([String: Value])

        public subscript(key: String) -> Value? {
            if case .dict(let d) = self { return d[key] }
            return nil
        }

        public var int: Int64? {
            switch self {
            case .int(let v): v
            case .double(let v) where v.rounded() == v && abs(v) < 9e18: Int64(v)
            case .bool(let b): b ? 1 : 0
            default: nil
            }
        }

        public var double: Double? {
            switch self {
            case .double(let v): v
            case .int(let v): Double(v)
            default: nil
            }
        }

        public var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        public var data: [UInt8]? {
            switch self {
            case .data(let d), .uuid(let d): d
            default: nil
            }
        }

        public var array: [Value]? {
            if case .array(let a) = self { return a }
            return nil
        }
    }

    // MARK: - Encoding

    /// Appends OPACK objects to a byte buffer. Containers: `dict(n)`/`array(n)` then
    /// exactly n pairs/items; when n ≥ 15 the container is open and `end()` must follow.
    public struct Writer {
        public var bytes: [UInt8]

        public init(capacity: Int = 128) {
            bytes = []
            bytes.reserveCapacity(capacity)
        }

        public mutating func null() { bytes.append(0x04) }

        public mutating func bool(_ v: Bool) { bytes.append(v ? 0x01 : 0x02) }

        /// Non-negative integers only: the Apple TV's reading of negative sized integers
        /// is unknown, so negative numbers go as doubles (`double`).
        public mutating func int(_ v: Int64) {
            precondition(v >= 0, "OPACK: negative integers are sent as doubles")
            // Signed widths: 200 in one byte would read as -56.
            if v < 0x28 {
                bytes.append(UInt8(v) + 8)
            } else if v <= 0x7F {
                bytes.append(0x30); appendLE(UInt64(v), 1)
            } else if v <= 0x7FFF {
                bytes.append(0x31); appendLE(UInt64(v), 2)
            } else if v <= 0x7FFF_FFFF {
                bytes.append(0x32); appendLE(UInt64(v), 4)
            } else {
                bytes.append(0x33); appendLE(UInt64(v), 8)
            }
        }

        public mutating func int(_ v: Int) { int(Int64(v)) }

        /// Unsigned values that may exceed Int64 (session ids): always 8 bytes.
        public mutating func uint(_ v: UInt64) {
            if v <= UInt64(Int64.max) { return int(Int64(v)) }
            bytes.append(0x33); appendLE(v, 8)
        }

        public mutating func double(_ v: Double) {
            bytes.append(0x36)
            appendLE(v.bitPattern, 8)
        }

        public mutating func string(_ s: String) {
            var s = s
            s.withUTF8 { utf8 in
                let n = utf8.count
                if n <= 0x20 {
                    bytes.append(0x40 + UInt8(n))
                } else if n <= 0xFF {
                    bytes.append(0x61); appendLE(UInt64(n), 1)
                } else if n <= 0xFFFF {
                    bytes.append(0x62); appendLE(UInt64(n), 2)
                } else if n <= 0xFF_FFFF {
                    bytes.append(0x63); appendLE(UInt64(n), 3)
                } else {
                    bytes.append(0x64); appendLE(UInt64(n), 4)
                }
                bytes.append(contentsOf: utf8)
            }
        }

        public mutating func data(_ d: some Collection<UInt8>) {
            let n = d.count
            if n <= 0x20 {
                bytes.append(0x70 + UInt8(n))
            } else if n <= 0xFF {
                bytes.append(0x91); appendLE(UInt64(n), 1)
            } else if n <= 0xFFFF {
                bytes.append(0x92); appendLE(UInt64(n), 2)
            } else if n <= 0xFFFF_FFFF {
                bytes.append(0x93); appendLE(UInt64(n), 4)
            } else {
                bytes.append(0x94); appendLE(UInt64(n), 8)
            }
            bytes.append(contentsOf: d)
        }

        public mutating func array(_ count: Int) { bytes.append(0xD0 + UInt8(min(count, 15))) }

        public mutating func dict(_ count: Int) { bytes.append(0xE0 + UInt8(min(count, 15))) }

        /// Closes an open container (one started with a count ≥ 15).
        public mutating func end() { bytes.append(0x03) }

        public mutating func value(_ v: Value) {
            switch v {
            case .null: null()
            case .bool(let b): bool(b)
            case .int(let i): if i >= 0 { int(i) } else { double(Double(i)) }
            case .double(let d): double(d)
            case .string(let s): string(s)
            case .data(let d): data(d)
            case .uuid(let u):
                bytes.append(0x05)
                bytes.append(contentsOf: u.prefix(16))
                if u.count < 16 { bytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - u.count)) }
            case .date(let d): bytes.append(0x06); appendLE(d.bitPattern, 8)
            case .array(let a):
                array(a.count)
                for item in a { value(item) }
                if a.count >= 15 { end() }
            case .dict(let d):
                dict(d.count)
                // Sorted for deterministic output (tests, logs); the receiver doesn't care.
                for k in d.keys.sorted() { string(k); value(d[k]!) }
                if d.count >= 15 { end() }
            }
        }

        private mutating func appendLE(_ v: UInt64, _ n: Int) {
            var v = v
            for _ in 0..<n {
                bytes.append(UInt8(truncatingIfNeeded: v))
                v >>= 8
            }
        }
    }

    /// `key=value` command-line arguments (tvctl raw) as a dictionary: integers, doubles
    /// (with a "."), true/false, else strings. Nil (with the bad argument) if one has no "=".
    public static func arguments(_ args: some Sequence<String>) -> Result<[String: Value], ProtocolError> {
        var out: [String: Value] = [:]
        for kv in args {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { return .failure(.malformed("bad argument \(kv)")) }
            let v = p[1]
            out[p[0]] = if let i = Int64(v) { .int(i) } else if v.contains("."), let d = Double(v) { .double(d) }
                else if v == "true" || v == "false" { .bool(v == "true") } else { .string(v) }
        }
        return .success(out)
    }

    public static func encode(_ v: Value) -> [UInt8] {
        var w = Writer()
        w.value(v)
        return w.bytes
    }

    // MARK: - Decoding

    public static func decode(_ bytes: [UInt8]) throws(ProtocolError) -> Value {
        var r = Reader(bytes: bytes)
        return try r.object(depth: 0)
    }

    struct Reader {
        let bytes: [UInt8]
        var i = 0
        var objects: [Value] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        private mutating func take(_ n: Int) throws(ProtocolError) -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= bytes.count else { throw .malformed("OPACK truncated") }
            defer { i += n }
            return bytes[i..<(i + n)]
        }

        private mutating func uintLE(_ n: Int) throws(ProtocolError) -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            for b in try take(n) {
                v |= UInt64(b) << shift
                shift += 8
            }
            return v
        }

        private mutating func remember(_ v: Value) -> Value {
            if !objects.contains(v) { objects.append(v) }
            return v
        }

        private mutating func string(_ n: Int) throws(ProtocolError) -> Value {
            let s = try take(n)
            guard let str = String(validating: s, as: UTF8.self) else { throw .malformed("OPACK string not UTF-8") }
            return remember(.string(str))
        }

        mutating func object(depth: Int) throws(ProtocolError) -> Value {
            guard depth < 32 else { throw .malformed("OPACK nesting too deep") }
            let tag = try take(1).first!
            switch tag {
            case 0x01: return .bool(true)
            case 0x02: return .bool(false)
            case 0x04: return .null
            case 0x05: return remember(.uuid(Array(try take(16))))
            case 0x06: return remember(.date(Double(bitPattern: try uintLE(8))))
            case 0x08...0x2F: return .int(Int64(tag - 8))
            case 0x30...0x33:
                let n = 1 << Int(tag & 0x0F)
                let v = try uintLE(n)
                // Sign-extend from n bytes.
                let shift = UInt64(64 - 8 * n)
                return remember(.int(Int64(bitPattern: v << shift) >> Int64(shift)))
            case 0x35: return remember(.double(Double(Float(bitPattern: UInt32(try uintLE(4))))))
            case 0x36: return remember(.double(Double(bitPattern: try uintLE(8))))
            case 0x40...0x60: return try string(Int(tag - 0x40))
            case 0x61...0x64: return try string(Int(try uintLE(Int(tag & 0x0F))))
            case 0x70...0x90: return remember(.data(Array(try take(Int(tag - 0x70)))))
            case 0x91...0x94:
                let n = try uintLE(1 << (Int(tag & 0x0F) - 1))
                guard n <= UInt64(bytes.count) else { throw .malformed("OPACK data length") }
                return remember(.data(Array(try take(Int(n)))))
            case 0xA0...0xC0: return try reference(Int(tag - 0xA0))
            case 0xC1...0xC4: return try reference(Int(try uintLE(Int(tag - 0xC0))))
            case 0xD0...0xDF:
                var items: [Value] = []
                if tag == 0xDF {
                    while try peek() != 0x03 { items.append(try object(depth: depth + 1)) }
                    i += 1
                } else {
                    items.reserveCapacity(Int(tag & 0x0F))
                    for _ in 0..<(tag & 0x0F) { items.append(try object(depth: depth + 1)) }
                }
                return .array(items)
            case 0xE0...0xEF:
                var d: [String: Value] = [:]
                func pair(_ r: inout Reader) throws(ProtocolError) {
                    let k = try r.object(depth: depth + 1)
                    let v = try r.object(depth: depth + 1)
                    switch k {
                    case .string(let s): d[s] = v
                    case .int(let n): d[String(n)] = v
                    default: break   // never seen in practice; dropped
                    }
                }
                if tag == 0xEF {
                    while try peek() != 0x03 { try pair(&self) }
                    i += 1
                } else {
                    for _ in 0..<(tag & 0x0F) { try pair(&self) }
                }
                return .dict(d)
            default:
                throw .malformed("OPACK tag 0x\(String(tag, radix: 16))")
            }
        }

        private func peek() throws(ProtocolError) -> UInt8 {
            guard i < bytes.count else { throw .malformed("OPACK unterminated container") }
            return bytes[i]
        }

        private func reference(_ index: Int) throws(ProtocolError) -> Value {
            guard index < objects.count else { throw .malformed("OPACK reference \(index)") }
            return objects[index]
        }
    }
}
