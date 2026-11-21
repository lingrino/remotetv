/// HAP TLV8, the encoding of pairing messages: tag (1 byte), length (1 byte), value.
/// Values longer than 255 bytes continue in consecutive items with the same tag, which
/// the decoder concatenates.
public enum TLV8 {
    public enum Tag: UInt8 {
        case method = 0x00
        case identifier = 0x01
        case salt = 0x02
        case publicKey = 0x03
        case proof = 0x04
        case encryptedData = 0x05
        case state = 0x06
        case error = 0x07
        case backOff = 0x08
        case signature = 0x0A
        case name = 0x11       // Apple: OPACK dictionary describing the controller
        case flags = 0x13
    }

    /// HAP error codes (`Tag.error`).
    public static func errorDescription(_ code: UInt8) -> String {
        switch code {
        case 1: "unknown error"
        case 2: "wrong PIN"
        case 3: "too many attempts, try again later"
        case 4: "the Apple TV can't pair with more devices"
        case 5: "too many failed attempts"
        case 6: "the Apple TV is busy pairing with another device"
        default: "error \(code)"
        }
    }

    public static func encode(_ items: [(Tag, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(items.reduce(0) { $0 + $1.1.count + 2 * ($1.1.count / 255 + 1) })
        for (tag, value) in items {
            if value.isEmpty {
                out.append(tag.rawValue)
                out.append(0)
                continue
            }
            var i = 0
            while i < value.count {
                let n = min(255, value.count - i)
                out.append(tag.rawValue)
                out.append(UInt8(n))
                out.append(contentsOf: value[i..<(i + n)])
                i += n
            }
        }
        return out
    }

    /// Decoded items by tag. Consecutive fragments of one tag are joined; a tag that
    /// appears again later (not adjacent) replaces the earlier value, which pairing
    /// messages never do.
    public struct Items {
        private var values: [UInt8: [UInt8]] = [:]

        public subscript(tag: Tag) -> [UInt8]? { values[tag.rawValue] }

        init(_ bytes: [UInt8]) throws(ProtocolError) {
            var i = 0
            var last: UInt8? = nil
            while i < bytes.count {
                guard i + 2 <= bytes.count else { throw .malformed("TLV8 header") }
                let tag = bytes[i], n = Int(bytes[i + 1])
                guard i + 2 + n <= bytes.count else { throw .malformed("TLV8 length") }
                let v = bytes[(i + 2)..<(i + 2 + n)]
                if last == tag { values[tag, default: []].append(contentsOf: v) } else { values[tag] = Array(v) }
                last = tag
                i += 2 + n
            }
        }
    }

    public static func decode(_ bytes: [UInt8]) throws(ProtocolError) -> Items {
        try Items(bytes)
    }
}
