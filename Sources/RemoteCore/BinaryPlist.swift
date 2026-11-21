/// Binary property lists (`bplist00`), reader and writer, including keyed-archiver UIDs
/// (which Foundation's PropertyListSerialization can read but not expose or write). The
/// Apple TV sends now-playing info and text-input sessions as NSKeyedArchiver archives in
/// this format and expects text edits the same way.
///
/// Format: "bplist00", objects, offset table, 32-byte trailer (offset int size, object ref
/// size, object count, top object, offset table offset). Object markers: 0x0_ null/bool,
/// 0x1_ int (2^n bytes, big-endian), 0x2_ real, 0x3_ date, 0x4_ data, 0x5_ ASCII,
/// 0x6_ UTF-16BE, 0x8_ UID, 0xA_ array, 0xD_ dict; low nibble 0xF = count follows as an int.
public enum Plist: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case date(Double)          // seconds since 2001-01-01
    case data([UInt8])
    case string(String)
    case uid(Int)
    case array([Plist])
    case dict([(String, Plist)])

    public static func == (a: Plist, b: Plist) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.int(x), .int(y)): x == y
        case let (.real(x), .real(y)): x == y
        case let (.date(x), .date(y)): x == y
        case let (.data(x), .data(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.uid(x), .uid(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.dict(x), .dict(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public subscript(key: String) -> Plist? {
        if case .dict(let d) = self { return d.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var double: Double? {
        switch self {
        case .real(let d), .date(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
    public var int: Int64? {
        switch self {
        case .int(let i): i
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }
    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        default: nil
        }
    }
    public var data: [UInt8]? { if case .data(let d) = self { d } else { nil } }
    public var uid: Int? { if case .uid(let u) = self { u } else { nil } }

    // MARK: - Reading

    public static func decode(_ bytes: [UInt8]) throws(ProtocolError) -> Plist {
        let r = try Reader(bytes)
        return try r.object(r.top, depth: 0)
    }

    private struct Reader {
        let b: [UInt8]
        let offsets: [Int]
        let refSize: Int
        let top: Int

        init(_ bytes: [UInt8]) throws(ProtocolError) {
            b = bytes
            guard b.count >= 40, b.starts(with: Array("bplist0".utf8)) else { throw .malformed("not a binary plist") }
            let t = b.count - 32
            let offSize = Int(b[t + 6])
            refSize = Int(b[t + 7])
            let count = Int(Reader.be(b[(t + 8)..<(t + 16)]))
            top = Int(Reader.be(b[(t + 16)..<(t + 24)]))
            let table = Int(Reader.be(b[(t + 24)..<(t + 32)]))
            guard (1...8).contains(offSize), (1...8).contains(refSize), count > 0, count < 1 << 20, top < count,
                  table >= 8, table + count * offSize <= t else { throw .malformed("plist trailer") }
            var o: [Int] = []
            o.reserveCapacity(count)
            for i in 0..<count {
                let s = table + i * offSize
                let v = Int(Reader.be(b[s..<(s + offSize)]))
                guard v >= 8, v < table else { throw .malformed("plist offset") }
                o.append(v)
            }
            offsets = o
        }

        static func be(_ s: ArraySlice<UInt8>) -> UInt64 {
            var v: UInt64 = 0
            for x in s { v = v << 8 | UInt64(x) }
            return v
        }

        private func slice(_ at: Int, _ n: Int) throws(ProtocolError) -> ArraySlice<UInt8> {
            guard n >= 0, at >= 0, at + n <= b.count - 32 else { throw .malformed("plist truncated") }
            return b[at..<(at + n)]
        }

        /// Count in the low nibble, or (0xF) as a following int object. Returns (count, start of payload).
        private func count(_ at: Int) throws(ProtocolError) -> (Int, Int) {
            let low = Int(b[at] & 0x0F)
            if low != 0x0F { return (low, at + 1) }
            let m = try slice(at + 1, 1).first!
            guard m >> 4 == 0x1 else { throw .malformed("plist count") }
            let n = 1 << Int(m & 0x0F)
            let v = Reader.be(try slice(at + 2, n))
            guard v < 1 << 28 else { throw .malformed("plist count too large") }
            return (Int(v), at + 2 + n)
        }

        private func refs(_ at: Int, _ n: Int) throws(ProtocolError) -> [Int] {
            let s = try slice(at, n * refSize)
            var out: [Int] = []
            out.reserveCapacity(n)
            var i = s.startIndex
            for _ in 0..<n {
                let r = Int(Reader.be(s[i..<(i + refSize)]))
                guard r < offsets.count else { throw .malformed("plist reference") }
                out.append(r)
                i += refSize
            }
            return out
        }

        func object(_ index: Int, depth: Int) throws(ProtocolError) -> Plist {
            guard depth < 64 else { throw .malformed("plist nesting") }
            let at = offsets[index]
            let m = b[at]
            switch m >> 4 {
            case 0x0:
                switch m {
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: return .null
                }
            case 0x1:
                let n = 1 << Int(m & 0x0F)
                guard n <= 16 else { throw .malformed("plist int size") }
                let s = try slice(at + 1, n)
                return .int(Int64(bitPattern: Reader.be(s.suffix(8))))
            case 0x2, 0x3:
                let n = 1 << Int(m & 0x0F)
                let s = try slice(at + 1, n)
                let v = n == 4 ? Double(Float(bitPattern: UInt32(Reader.be(s)))) : Double(bitPattern: Reader.be(s))
                return m >> 4 == 0x2 ? .real(v) : .date(v)
            case 0x4:
                let (n, p) = try count(at)
                return .data(Array(try slice(p, n)))
            case 0x5:
                let (n, p) = try count(at)
                return .string(String(decoding: try slice(p, n), as: UTF8.self))
            case 0x6:
                let (n, p) = try count(at)
                let s = try slice(p, 2 * n)
                var units: [UInt16] = []
                units.reserveCapacity(n)
                var i = s.startIndex
                while i < s.endIndex { units.append(UInt16(s[i]) << 8 | UInt16(s[i + 1])); i += 2 }
                return .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                let n = Int(m & 0x0F) + 1
                return .uid(Int(Reader.be(try slice(at + 1, n))))
            case 0xA:
                let (n, p) = try count(at)
                var out: [Plist] = []
                out.reserveCapacity(n)
                for r in try refs(p, n) { out.append(try object(r, depth: depth + 1)) }
                return .array(out)
            case 0xD:
                let (n, p) = try count(at)
                let keys = try refs(p, n), values = try refs(p + n * refSize, n)
                var out: [(String, Plist)] = []
                out.reserveCapacity(n)
                for (k, v) in zip(keys, values) {
                    guard case .string(let key) = try object(k, depth: depth + 1) else { throw .malformed("plist dict key") }
                    out.append((key, try object(v, depth: depth + 1)))
                }
                return .dict(out)
            default:
                throw .malformed("plist marker 0x\(String(m, radix: 16))")
            }
        }
    }

    // MARK: - Writing

    /// Binary plist bytes. No object sharing (every value is its own object); fine for
    /// the small archives sent here.
    public func encode() -> [UInt8] {
        var objects: [[UInt8]] = []
        // Flatten: assign indices depth-first, children after parents.
        var flat: [Plist] = []
        var children: [[Int]] = []
        func add(_ v: Plist) -> Int {
            let i = flat.count
            flat.append(v)
            children.append([])
            switch v {
            case .array(let a):
                var c: [Int] = []
                for x in a { c.append(add(x)) }
                children[i] = c
            case .dict(let d):
                var c: [Int] = []
                for (k, _) in d { c.append(add(.string(k))) }
                for (_, x) in d { c.append(add(x)) }
                children[i] = c
            default: break
            }
            return i
        }
        _ = add(self)
        let refSize = flat.count < 256 ? 1 : (flat.count < 65536 ? 2 : 4)
        func ref(_ r: Int) -> [UInt8] { (0..<refSize).reversed().map { UInt8(truncatingIfNeeded: r >> ($0 * 8)) } }
        func marker(_ type: UInt8, _ n: Int) -> [UInt8] {
            if n < 15 { return [type << 4 | UInt8(n)] }
            return [type << 4 | 0x0F] + Plist.intBytes(Int64(n))
        }
        for (i, v) in flat.enumerated() {
            var o: [UInt8]
            switch v {
            case .null: o = [0x00]
            case .bool(let x): o = [x ? 0x09 : 0x08]
            case .int(let x): o = Plist.intBytes(x)
            case .real(let x): o = [0x23] + Plist.be(x.bitPattern, 8)
            case .date(let x): o = [0x33] + Plist.be(x.bitPattern, 8)
            case .data(let d): o = marker(0x4, d.count) + d
            case .string(let s):
                if s.utf8.allSatisfy({ $0 < 0x80 }) {
                    o = marker(0x5, s.utf8.count) + Array(s.utf8)
                } else {
                    let u = Array(s.utf16)
                    o = marker(0x6, u.count)
                    for x in u { o.append(UInt8(x >> 8)); o.append(UInt8(x & 0xFF)) }
                }
            case .uid(let u):
                let n = u < 256 ? 1 : (u < 65536 ? 2 : 4)
                o = [0x80 | UInt8(n - 1)] + Plist.be(UInt64(u), n)
            case .array(let a): o = marker(0xA, a.count); for c in children[i] { o += ref(c) }
            case .dict(let d): o = marker(0xD, d.count); for c in children[i] { o += ref(c) }
            }
            objects.append(o)
        }
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for o in objects { offsets.append(out.count); out += o }
        let table = out.count
        let offSize = table < 256 ? 1 : (table < 65536 ? 2 : 4)
        for off in offsets { out += Plist.be(UInt64(off), offSize) }
        out += [0, 0, 0, 0, 0, 0, UInt8(offSize), UInt8(refSize)]
        out += Plist.be(UInt64(objects.count), 8) + Plist.be(0, 8) + Plist.be(UInt64(table), 8)
        return out
    }

    private static func be(_ v: UInt64, _ n: Int) -> [UInt8] {
        (0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (UInt64($0) * 8)) }
    }

    private static func intBytes(_ v: Int64) -> [UInt8] {
        if v >= 0 && v < 1 << 8 { return [0x10] + be(UInt64(v), 1) }
        if v >= 0 && v < 1 << 16 { return [0x11] + be(UInt64(v), 2) }
        if v >= 0 && v < 1 << 32 { return [0x12] + be(UInt64(v), 4) }
        return [0x13] + be(UInt64(bitPattern: v), 8)
    }
}

/// Reads NSKeyedArchiver archives: `$objects` + `$top`, with UIDs resolved on access.
public struct KeyedArchive {
    public let objects: [Plist]
    public let top: [(String, Plist)]

    public init(_ bytes: [UInt8]) throws(ProtocolError) {
        let p = try Plist.decode(bytes)
        guard case .array(let objs)? = p["$objects"], case .dict(let t)? = p["$top"] else {
            throw .malformed("not a keyed archive")
        }
        objects = objs
        top = t
    }

    /// The object a value refers to (UIDs followed; "$null" becomes nil).
    public func resolve(_ v: Plist?) -> Plist? {
        guard var v else { return nil }
        var hops = 0
        while case .uid(let u) = v, u < objects.count, hops < 8 { v = objects[u]; hops += 1 }
        if case .string("$null") = v { return nil }
        return v
    }

    public var root: Plist? { resolve(top.first { $0.0 == "root" }?.1 ?? top.first?.1) }

    /// `object.key`, resolved; NSString/NSUUID wrappers unwrapped.
    public func field(_ object: Plist?, _ key: String) -> Plist? {
        guard let v = resolve(object?[key]) else { return nil }
        if let s = resolve(v["NS.string"]) { return s }
        if let u = v["NS.uuidbytes"] { return u }
        return v
    }

    public func className(_ object: Plist?) -> String? {
        resolve(object?["$class"])?["$classname"]?.string
    }

    /// Follows a key path ("documentState.docSt.contextBeforeInput").
    public func path(_ object: Plist?, _ keys: String...) -> Plist? {
        var cur = object
        for k in keys { cur = field(cur, k) }
        return cur
    }
}
