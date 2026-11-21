import Testing
@testable import RemoteCore

// MARK: - OPACK

private func enc(_ v: OPACK.Value) -> [UInt8] { OPACK.encode(v) }

@Test func opackScalars() {
    #expect(enc(.bool(true)) == [0x01])
    #expect(enc(.bool(false)) == [0x02])
    #expect(enc(.null) == [0x04])
    #expect(enc(.int(0)) == [0x08])
    #expect(enc(.int(0x27)) == [0x2F])
    #expect(enc(.int(0x28)) == [0x30, 0x28])
    #expect(enc(.int(0x80)) == [0x31, 0x80, 0x00])      // 0x30 0x80 would be -128
    #expect(enc(.int(0x1FF)) == [0x31, 0xFF, 0x01])
    #expect(enc(.int(0x8000)) == [0x32, 0x00, 0x80, 0x00, 0x00])
    #expect(enc(.int(0x1FF_FFFF)) == [0x32, 0xFF, 0xFF, 0xFF, 0x01])
    #expect(enc(.int(0x1FF_FFFF_FFFF_FFFF)) == [0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    #expect(enc(.double(1.0)) == [0x36, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F])
    #expect(enc(.int(-10)) == enc(.double(-10)))   // negatives go as doubles
}

@Test func opackStringsAndData() {
    #expect(enc(.string("a")) == [0x41, 0x61])
    #expect(enc(.string(String(repeating: "a", count: 32))) == [0x60] + [UInt8](repeating: 0x61, count: 32))
    #expect(enc(.string(String(repeating: "a", count: 33))) == [0x61, 0x21] + [UInt8](repeating: 0x61, count: 33))
    #expect(enc(.string(String(repeating: "a", count: 256))) == [0x62, 0x00, 0x01] + [UInt8](repeating: 0x61, count: 256))
    #expect(enc(.data([0xAC])) == [0x71, 0xAC])
    #expect(enc(.data([UInt8](repeating: 0xAD, count: 32))) == [0x90] + [UInt8](repeating: 0xAD, count: 32))
    #expect(enc(.data([UInt8](repeating: 0x61, count: 33))) == [0x91, 0x21] + [UInt8](repeating: 0x61, count: 33))
    #expect(enc(.data([UInt8](repeating: 0x61, count: 256))) == [0x92, 0x00, 0x01] + [UInt8](repeating: 0x61, count: 256))
}

@Test func opackContainers() {
    #expect(enc(.array([])) == [0xD0])
    #expect(enc(.array([.int(1), .string("test"), .bool(false)])) == [0xD3, 0x09, 0x44, 0x74, 0x65, 0x73, 0x74, 0x02])
    #expect(enc(.array([.array([.bool(true)])])) == [0xD1, 0xD1, 0x01])
    #expect(enc(.dict([:])) == [0xE0])
    #expect(enc(.dict(["a": .int(12)])) == [0xE1, 0x41, 0x61, 0x14])
    let fifteen = OPACK.Value.array([OPACK.Value](repeating: .int(1), count: 15))
    #expect(enc(fifteen) == [0xDF] + [UInt8](repeating: 0x09, count: 15) + [0x03])
}

@Test func opackRoundTrip() throws {
    let v = OPACK.Value.dict([
        "_i": .string("_systemInfo"), "_t": .int(2), "_x": .int(54321),
        "_c": .dict(["name": .string("RemoteTV"), "_sv": .string("170.18"), "pi": .double(3.25),
                     "list": .array([.null, .bool(true), .data([1, 2, 3])]),
                     "big": .int(0x1_0000_0000), "long": .string(String(repeating: "é", count: 200))]),
    ])
    #expect(try OPACK.decode(enc(v)) == v)
}

@Test func opackDecodesReferencesAndOpenContainers() throws {
    // ["a", "a"] with the second "a" as a reference to object #0.
    #expect(try OPACK.decode([0xD2, 0x41, 0x61, 0xA0]) == .array([.string("a"), .string("a")]))
    // Open array of 15 "a"s, 14 of them references (pyatv's encoding).
    let open: [UInt8] = [0xDF, 0x41, 0x61] + [UInt8](repeating: 0xA0, count: 14) + [0x03]
    #expect(try OPACK.decode(open) == .array([OPACK.Value](repeating: .string("a"), count: 15)))
    // Open dictionary, one-byte reference index.
    #expect(try OPACK.decode([0xEF, 0x41, 0x6B, 0x43, 0x76, 0x61, 0x6C, 0x03]) == .dict(["k": .string("val")]))
    #expect(try OPACK.decode([0xD2, 0x41, 0x61, 0xC1, 0x00]) == .array([.string("a"), .string("a")]))
    // UUID, float32, sized integers.
    #expect(try OPACK.decode([0x05] + [UInt8](repeating: 0x12, count: 16)) == .uuid([UInt8](repeating: 0x12, count: 16)))
    #expect(try OPACK.decode([0x35, 0x00, 0x00, 0x80, 0x3F]) == .double(1.0))
    #expect(try OPACK.decode([0x31, 0x01, 0x00]) == .int(1))
    #expect(try OPACK.decode([0x31, 0xC6, 0xE5]) == .int(-6714))   // as the TV sends error codes
    #expect(try OPACK.decode([0x30, 0xFF]) == .int(-1))
    #expect(try OPACK.decode([0x32, 0xFF, 0xFF, 0xFF, 0x7F]) == .int(Int64(Int32.max)))
}

@Test func opackRejectsGarbage() {
    #expect(throws: ProtocolError.self) { try OPACK.decode([]) }
    #expect(throws: ProtocolError.self) { try OPACK.decode([0x43, 0x61]) }          // truncated string
    #expect(throws: ProtocolError.self) { try OPACK.decode([0xD2, 0x08]) }          // missing item
    #expect(throws: ProtocolError.self) { try OPACK.decode([0xDF, 0x08]) }          // unterminated
    #expect(throws: ProtocolError.self) { try OPACK.decode([0xA3]) }                // bad reference
    #expect(throws: ProtocolError.self) { try OPACK.decode([0x94] + [UInt8](repeating: 0xFF, count: 8)) }
    #expect(throws: ProtocolError.self) { try OPACK.decode([0xFF]) }
    #expect(throws: ProtocolError.self) { try OPACK.decode([UInt8](repeating: 0xD1, count: 100) + [0x08]) }   // too deep
}

@Test func opackAccessors() throws {
    let v = try OPACK.decode(enc(.dict(["_c": .dict(["_sid": .int(7), "state": .double(3)])])))
    #expect(v["_c"]?["_sid"]?.int == 7)
    #expect(v["_c"]?["state"]?.int == 3)
    #expect(v["nope"] == nil)
}

// MARK: - TLV8

@Test func tlv8RoundTripAndFragments() throws {
    let long = [UInt8](0..<255) + [UInt8](0..<200)
    let bytes = TLV8.encode([(.state, [1]), (.publicKey, long), (.method, [])])
    // 455 bytes of public key → fragments of 255 and 200.
    #expect(bytes.count == 3 + (2 + 255) + (2 + 200) + 2)
    #expect(Array(bytes[0..<3]) == [0x06, 0x01, 0x01])
    let items = try TLV8.decode(bytes)
    #expect(items[.state] == [1])
    #expect(items[.publicKey] == long)
    #expect(items[.method] == [])
    #expect(items[.salt] == nil)
}

@Test func tlv8RejectsTruncation() {
    #expect(throws: ProtocolError.self) { try TLV8.decode([0x06]) }
    #expect(throws: ProtocolError.self) { try TLV8.decode([0x06, 0x02, 0x01]) }
}
