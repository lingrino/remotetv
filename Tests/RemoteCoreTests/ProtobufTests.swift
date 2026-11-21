import Foundation
import Testing
@testable import RemoteCore

@Test func protobufRoundTrip() throws {
    var w = ProtoWriter()
    w.varint(1, 150)                 // classic example: 08 96 01
    w.string(2, "testing")
    w.double(3, 1.5)
    w.float(4, 2.25)
    w.bool(5, true)
    w.int(6, -1)
    w.message(7) { m in m.string(1, "inner"); m.varint(2, 3) }
    w.message(7) { m in m.string(1, "second") }
    w.data(8, [0x03, 0x8E, 0x02])    // packed varints 3, 270
    #expect(Array(w.bytes.prefix(3)) == [0x08, 0x96, 0x01])
    let m = try ProtoMessage(w.bytes)
    #expect(m.uint(1) == 150)
    #expect(m.string(2) == "testing")
    #expect(m.double(3) == 1.5)
    #expect(m.float(4) == 2.25)
    #expect(m.bool(5) == true)
    #expect(m.int(6) == -1)
    #expect(m.messages(7).count == 2)
    #expect(m.message(7)?.string(1) == "second")      // last wins for singular access
    #expect(m.messages(7).first?.uint(2) == 3)
    #expect(m.uints(8) == [3, 270])
    #expect(m.string(99) == nil)
}

@Test func protobufRejectsGarbage() {
    #expect(throws: ProtocolError.self) { try ProtoMessage([0x08]) }            // varint missing
    #expect(throws: ProtocolError.self) { try ProtoMessage([0x12, 0x05, 0x01]) } // length past end
    #expect(throws: ProtocolError.self) { try ProtoMessage([0x0B]) }            // wire type 3
}

@Test func hapCipherRoundTripAcrossFrames() throws {
    let k1 = SymmetricKeyBytes.make(), k2 = SymmetricKeyBytes.make()
    var a = HAPCipher(send: k1, receive: k2)
    var b = HAPCipher(send: k2, receive: k1)
    let big = (0..<3000).map { UInt8($0 & 0xFF) }
    let sealed = a.seal(big)
    #expect(sealed.count == 3000 + 3 * 18)     // 1024 + 1024 + 952, each + 2-byte length + tag
    // Arrives in odd-sized pieces.
    var got: [UInt8] = []
    var i = 0
    while i < sealed.count {
        let n = min(700, sealed.count - i)
        got += try b.open(Array(sealed[i..<(i + n)]))
        i += n
    }
    #expect(got == big)
    let back = b.seal([1, 2, 3])
    #expect(try a.open(back) == [1, 2, 3])
}

@Test func dataStreamFrameHeader() {
    let f = AirPlayTunnel.frame(type: "sync", command: "comm", seqno: 0x0102030405060708, payload: [9, 9])
    #expect(f.count == 34)
    #expect(Array(f[0..<4]) == [0, 0, 0, 34])
    #expect(Array(f[4..<8]) == Array("sync".utf8) && f[8..<16].allSatisfy { $0 == 0 })
    #expect(Array(f[16..<20]) == Array("comm".utf8))
    #expect(Array(f[20..<28]) == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(Array(f[32...]) == [9, 9])
}

@Test func httpMessageParsing() throws {
    var buf = Array("RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: 4\r\n\r\nbodyRTSP/1.0 404".utf8)
    let m = try #require(try HTTPMessage.take(from: &buf))
    #expect(m.status == 200)
    #expect(m.header("cseq") == "3")
    #expect(m.body == Array("body".utf8))
    #expect(buf == Array("RTSP/1.0 404".utf8))
    #expect(try HTTPMessage.take(from: &buf) == nil)   // incomplete
}

import CryptoKit
enum SymmetricKeyBytes {
    static func make() -> SymmetricKey { SymmetricKey(size: .bits256) }
}
