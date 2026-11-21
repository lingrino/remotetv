import Foundation
import Testing
@testable import RemoteCore

// Archives shaped like the TV's (same classes and keys), written by Python's plistlib.
private let nowPlayingArchive = Hex.decode("62706c6973743030d4010203040506070a582476657273696f6e592461726368697665725424746f7058246f626a6563747312000186a05f100f4e534b657965644172636869766572d1080954726f6f748001a80b0c1c223235363755246e756c6cd80d0e0f10111213141516171818191a1b5624636c6173735c706c61796261636b526174655d706c61796261636b53746174655f100f63617074696f6e73456e61626c65645f101668617356616c696443617074696f6e4f7074696f6e7359696d61676544617461586d657461646174615a6964656e7469666965728002233ff0000000000000100109800080038005d21d1e1f205a24636c6173736e616d655824636c61737365735f1012545652434e6f77506c6179696e67496e666fa21f21584e534f626a656374d80d232425262728292a2b2c2d2e2f3031557469746c655c657069736f64655469746c65586475726174696f6e5a74696d654f66667365745974696d657374616d705862756e646c654944546b696e648004800680002340ac21000000000023405e1000000000002341c7d7840040000080071000d21d1e33345f1016545652434e6f77506c6179696e674d65746164617461a23321564142434445466f101400540065007300740020004d006f00760069006500202014002000dc006e00ef0063006f006400655f1012636f6d2e6578616d706c652e706c6179657200080011001a00240029003200370049004c00510053005c00620073007a0087009500a700c000ca00d300de00e000e900eb00ec00ee00f000f200f70102010b01200123012c013d0143015001590164016e0177017c017e01800182018b0194019d019f01a101a601bf01c201c901f40000000000000201000000000000003800000000000000000000000000000209"[...])!
private let textSessionArchive = Hex.decode("62706c6973743030d4010203040506070c582476657273696f6e592461726368697665725424746f7058246f626a6563747312000186a05f10105254494b657965644172636869766572d208090a0b5b73657373696f6e555549445d646f63756d656e74537461746580018002a70d0e0f141a1e1f55246e756c6c4f1010000102030405060708090a0b0c0d0e0fd2101112135624636c61737355646f63537480038004d2151617185a24636c6173736e616d655824636c61737365735f1010525449446f63756d656e745374617465a21719584e534f626a656374d2101b1c1d5f1012636f6e746578744265666f7265496e707574800680055568656c6c6fd2151620215f100f5449446f63756d656e745374617465a2201900080011001a0024002900320037004a004f005b0069006b006d0075007b008e0093009a00a000a200a400a900b400bd00d000d300dc00e100f600f800fa010001050117000000000000020100000000000000220000000000000000000000000000011a"[...])!

private let sample = Plist.dict([
    ("null", .null), ("t", .bool(true)), ("f", .bool(false)),
    ("small", .int(7)), ("int16", .int(300)), ("int32", .int(70000)), ("int64", .int(1 << 40)), ("neg", .int(-5)),
    ("real", .real(3.25)), ("date", .date(800000000.5)),
    ("data", .data([1, 2, 3])), ("bigdata", .data([UInt8](repeating: 9, count: 300))),
    ("ascii", .string("hello")), ("unicode", .string("Ünïcode ✓")), ("long", .string(String(repeating: "x", count: 40))),
    ("uid", .uid(3)), ("bigUID", .uid(70000)),
    ("array", .array((0..<20).map { .int(Int64($0)) })),
    ("nested", .dict([("a", .array([.dict([("b", .string("c"))])]))])),
])

@Test func plistRoundTrip() throws {
    #expect(try Plist.decode(sample.encode()) == sample)
}

@Test func plistOutputReadsWithFoundation() throws {
    let noUIDs = Plist.dict([("s", .string("Ünïcode")), ("n", .int(-5)), ("r", .real(1.5)), ("d", .data([1, 2])),
                             ("a", .array((0..<20).map { .int(Int64($0)) })), ("b", .bool(true))])
    let obj = try PropertyListSerialization.propertyList(from: Data(noUIDs.encode()), format: nil) as? [String: Any]
    #expect(obj?["s"] as? String == "Ünïcode")
    #expect(obj?["n"] as? Int == -5)
    #expect(obj?["r"] as? Double == 1.5)
    #expect(obj?["d"] as? Data == Data([1, 2]))
    #expect((obj?["a"] as? [Int])?.count == 20)
    #expect(obj?["b"] as? Bool == true)
}

@Test func plistReadsFoundationOutput() throws {
    let src: [String: Any] = ["s": "Ünïcode ✓", "n": 123456789, "neg": -2, "r": 2.5, "d": Data([7, 8]),
                              "a": Array(0..<30), "date": Date(timeIntervalSinceReferenceDate: 1000)]
    let bytes = try PropertyListSerialization.data(fromPropertyList: src, format: .binary, options: 0)
    let p = try Plist.decode(Array(bytes))
    #expect(p["s"]?.string == "Ünïcode ✓")
    #expect(p["n"]?.int == 123456789)
    #expect(p["neg"]?.int == -2)
    #expect(p["r"]?.double == 2.5)
    #expect(p["d"]?.data == [7, 8])
    #expect(p["date"] == .date(1000))
    if case .array(let a)? = p["a"] { #expect(a.count == 30 && a[29] == .int(29)) } else { Issue.record("array") }
}

@Test func plistRejectsGarbage() {
    #expect(throws: ProtocolError.self) { try Plist.decode([]) }
    #expect(throws: ProtocolError.self) { try Plist.decode(Array("bplist00".utf8) + [UInt8](repeating: 0, count: 40)) }
    var b = sample.encode()
    b[b.count - 9] = 0xFF   // offset table offset points past the end
    #expect(throws: ProtocolError.self) { try Plist.decode(b) }
}

@Test func nowPlayingFromArchive() throws {
    let np = try #require(NowPlaying(archive: nowPlayingArchive))
    #expect(np.title == "Test Movie — Ünïcode")
    #expect(np.subtitle == nil)
    #expect(np.duration == 3600.5)
    #expect(np.elapsed == 120.25)
    #expect(np.timestamp == 800000000.5)
    #expect(np.rate == 1 && np.state == 1 && np.isPlaying)
    #expect(np.captionsEnabled && np.hasCaptions)
    #expect(np.bundleID == "com.example.player")
    #expect(np.artwork == nil)
    let later = Date(timeIntervalSinceReferenceDate: 800000000.5 + 10)
    #expect(abs(np.position(at: later) - 130.25) < 0.001)
    let wayLater = Date(timeIntervalSinceReferenceDate: 800000000.5 + 99999)
    #expect(np.position(at: wayLater) == 3600.5)   // clamped
}

@Test func pausedPositionDoesNotAdvance() {
    let np = NowPlaying(title: "x", duration: 100, elapsed: 40, timestamp: 0, rate: 0, state: 2)
    #expect(np.position(at: Date(timeIntervalSinceReferenceDate: 50)) == 40)
}

@Test func textSessionFromArchive() throws {
    let s = try #require(TextSession(archive: textSessionArchive))
    #expect(s.uuid == Array(0..<16))
    #expect(s.text == "hello")
}

@Test func rtiOperationsArchive() throws {
    let bytes = RTI.replace(session: Array(0..<16), with: "abc")
    // Foundation parses it too (independent reader).
    #expect(try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) is [String: Any])
    let a = try KeyedArchive(bytes)
    let ops = a.resolve(a.top.first { $0.0 == "textOperations" }?.1)
    #expect(a.className(ops) == "RTITextOperations")
    #expect(a.field(ops, "textToAssert")?.string == "abc")
    #expect(a.field(ops, "targetSessionUUID")?.data == Array(0..<16))
    #expect(a.className(a.field(ops, "keyboardOutput")) == "TIKeyboardOutput")
    let p = try Plist.decode(bytes)
    #expect(p["$archiver"]?.string == "RTIKeyedArchiver")
    let edit = try KeyedArchive(RTI.edit(session: Array(0..<16), delete: 2, insert: "xy"))
    let ops2 = edit.resolve(edit.top.first?.1)
    let out = edit.field(ops2, "keyboardOutput")
    #expect(edit.field(out, "insertionText")?.string == "xy")
    #expect(edit.field(out, "deletionCount")?.int == 2)
    #expect(edit.field(ops2, "textToAssert") == nil)
}

@Test func rtiDiff() {
    #expect(RTI.diff(from: "", to: "hel") == (0, "hel"))
    #expect(RTI.diff(from: "hel", to: "hello") == (0, "lo"))
    #expect(RTI.diff(from: "hello", to: "hell") == (1, ""))
    #expect(RTI.diff(from: "hello", to: "help") == (2, "p"))
    #expect(RTI.diff(from: "hello", to: "") == (5, ""))
    #expect(RTI.diff(from: "café", to: "cafés") == (0, "s"))
    #expect(RTI.diff(from: "a👍🏽", to: "a") == (1, ""))   // one character, several code points
}
