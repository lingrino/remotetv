/// The protobuf wire format, hand-rolled for the few MRP messages used (no schema
/// compiler, no dependency). Writer appends fields; Message decodes one level into
/// (field number, value) pairs and decodes nested messages on access.
///
/// Wire types: 0 varint · 1 64-bit (double) · 2 length-delimited (string, bytes,
/// message, packed repeated) · 5 32-bit (float).
struct ProtoWriter {
    var bytes: [UInt8] = []

    private mutating func key(_ field: Int, _ wire: UInt64) { raw(UInt64(field) << 3 | wire) }

    mutating func raw(_ v: UInt64) {
        var v = v
        while v >= 0x80 { bytes.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        bytes.append(UInt8(v))
    }

    mutating func varint(_ field: Int, _ v: UInt64) { key(field, 0); raw(v) }
    mutating func int(_ field: Int, _ v: Int) { varint(field, UInt64(bitPattern: Int64(v))) }
    mutating func bool(_ field: Int, _ v: Bool) { varint(field, v ? 1 : 0) }

    mutating func double(_ field: Int, _ v: Double) {
        key(field, 1)
        var b = v.bitPattern
        for _ in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: b)); b >>= 8 }
    }

    mutating func float(_ field: Int, _ v: Float) {
        key(field, 5)
        var b = v.bitPattern
        for _ in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: b)); b >>= 8 }
    }

    mutating func data(_ field: Int, _ d: [UInt8]) { key(field, 2); raw(UInt64(d.count)); bytes += d }
    mutating func string(_ field: Int, _ s: String) { data(field, Array(s.utf8)) }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var w = ProtoWriter()
        build(&w)
        data(field, w.bytes)
    }
}

struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    let fields: [(Int, Value)]

    init(_ bytes: ArraySlice<UInt8>) throws(ProtocolError) {
        var out: [(Int, Value)] = []
        var i = bytes.startIndex
        func varint() throws(ProtocolError) -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < bytes.endIndex, shift < 64 else { throw .malformed("protobuf varint") }
                let b = bytes[i]; i += 1
                v |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
        }
        while i < bytes.endIndex {
            let k = try varint()
            let field = Int(k >> 3)
            switch k & 7 {
            case 0: out.append((field, .varint(try varint())))
            case 1:
                guard bytes.endIndex - i >= 8 else { throw .malformed("protobuf fixed64") }
                var v: UInt64 = 0
                for j in 0..<8 { v |= UInt64(bytes[i + j]) << (8 * UInt64(j)) }
                i += 8
                out.append((field, .fixed64(v)))
            case 2:
                let n = try varint()
                guard n <= UInt64(bytes.endIndex - i) else { throw .malformed("protobuf length") }
                out.append((field, .bytes(bytes[i..<(i + Int(n))])))
                i += Int(n)
            case 5:
                guard bytes.endIndex - i >= 4 else { throw .malformed("protobuf fixed32") }
                var v: UInt32 = 0
                for j in 0..<4 { v |= UInt32(bytes[i + j]) << (8 * UInt32(j)) }
                i += 4
                out.append((field, .fixed32(v)))
            default:
                throw .malformed("protobuf wire type \(k & 7)")
            }
        }
        fields = out
    }

    init(_ bytes: [UInt8]) throws(ProtocolError) { try self.init(bytes[...]) }

    private func last(_ f: Int) -> Value? { fields.last { $0.0 == f }?.1 }

    func has(_ f: Int) -> Bool { fields.contains { $0.0 == f } }

    func uint(_ f: Int) -> UInt64? { if case .varint(let v)? = last(f) { v } else { nil } }
    func int(_ f: Int) -> Int? { uint(f).map { Int(Int64(bitPattern: $0)) } }
    func bool(_ f: Int) -> Bool? { uint(f).map { $0 != 0 } }

    func double(_ f: Int) -> Double? {
        switch last(f) {
        case .fixed64(let v)?: Double(bitPattern: v)
        case .fixed32(let v)?: Double(Float(bitPattern: v))
        default: nil
        }
    }

    func float(_ f: Int) -> Float? {
        switch last(f) {
        case .fixed32(let v)?: Float(bitPattern: v)
        case .fixed64(let v)?: Float(Double(bitPattern: v))
        default: nil
        }
    }

    func bytes(_ f: Int) -> [UInt8]? { if case .bytes(let b)? = last(f) { Array(b) } else { nil } }
    func string(_ f: Int) -> String? { if case .bytes(let b)? = last(f) { String(decoding: b, as: UTF8.self) } else { nil } }
    func message(_ f: Int) -> ProtoMessage? { if case .bytes(let b)? = last(f) { try? ProtoMessage(b) } else { nil } }

    func messages(_ f: Int) -> [ProtoMessage] {
        fields.compactMap { if $0.0 == f, case .bytes(let b) = $0.1 { try? ProtoMessage(b) } else { nil } }
    }

    /// Repeated varints, packed or not.
    func uints(_ f: Int) -> [UInt64] {
        var out: [UInt64] = []
        for (n, v) in fields where n == f {
            switch v {
            case .varint(let x): out.append(x)
            case .bytes(let b):
                var i = b.startIndex
                while i < b.endIndex {
                    var x: UInt64 = 0, s: UInt64 = 0
                    while i < b.endIndex { let c = b[i]; i += 1; x |= UInt64(c & 0x7F) << s; s += 7; if c & 0x80 == 0 { break } }
                    out.append(x)
                }
            default: break
            }
        }
        return out
    }
}
