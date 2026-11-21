import CryptoKit
import Foundation
import Testing
@testable import RemoteCore

/// A HAP accessory (the Apple TV's side) built from the spec, to run our controller
/// against: SRP server, M4/M6, pair-verify M2/M4.
private struct FakeAccessory {
    let pin: String
    let id = Array("TV-1234".utf8)
    let ltsk = Curve25519.Signing.PrivateKey()
    let salt = PairSetup.random(16)
    let b = PairSetup.random(32)
    let mont = Montgomery(modulus: SRPClient.N)

    var verifier: BigUInt {
        let x = BigUInt(bytes: H(salt, H(Array("Pair-Setup:\(pin)".utf8))))
        return mont.pow(SRPClient.g, x)
    }

    var k: BigUInt { BigUInt(bytes: H(SRPClient.N.bytes(width: 384), SRPClient.g.bytes(width: 384))) }

    var B: [UInt8] {
        mont.reduce(mont.mulMod(k, verifier) + mont.pow(SRPClient.g, BigUInt(bytes: b))).bytes(width: 384)
    }

    var m2: [UInt8] { TLV8.encode([(.state, [2]), (.salt, salt), (.publicKey, B)]) }

    /// Server side of M3 → (M4, K).
    func m4(_ m3: [UInt8]) throws -> ([UInt8], [UInt8]) {
        let items = try TLV8.decode(m3)
        let A = items[.publicKey]!, M1 = items[.proof]!
        let u = BigUInt(bytes: H(A, B))
        let S = mont.pow(mont.mulMod(BigUInt(bytes: A), mont.pow(verifier, u)), BigUInt(bytes: b))
        let K = H(S.bytes(width: 384))
        // The client's proof must match what the server computes.
        let hN = H(SRPClient.N.bytes(width: 384)), hg = H([5])
        let expected = H(zip(hN, hg).map { $0 ^ $1 }, H(Array("Pair-Setup".utf8)), salt, A, B, K)
        #expect(expected == M1)
        return (TLV8.encode([(.state, [4]), (.proof, H(A, M1, K))]), K)
    }

    func m6(_ m5: [UInt8], K: [UInt8]) throws -> ([UInt8], clientID: [UInt8], clientLTPK: [UInt8]) {
        let key = hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let inner = try TLV8.decode(try open(try TLV8.decode(m5)[.encryptedData]!, key: key, nonce: "PS-Msg05"))
        let cid = inner[.identifier]!, ltpk = inner[.publicKey]!, sig = inner[.signature]!
        let x = hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: ltpk).isValidSignature(sig, for: x.bytes + cid + ltpk))
        #expect(try OPACK.decode(inner[.name]!)["name"]?.string == "Test")
        let ax = hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let pub = Array(ltsk.publicKey.rawRepresentation)
        let mySig = Array(try ltsk.signature(for: ax.bytes + id + pub))
        let tlv = TLV8.encode([(.identifier, id), (.publicKey, pub), (.signature, mySig)])
        return (TLV8.encode([(.state, [6]), (.encryptedData, try seal(tlv, key: key, nonce: "PS-Msg06"))]), cid, ltpk)
    }
}

@Test func pairSetupAgainstFakeAccessory() throws {
    let tv = FakeAccessory(pin: "4321")
    #expect(PairSetup.m1() == [0x00, 0x01, 0x00, 0x06, 0x01, 0x01])
    let ps = try PairSetup(m2: tv.m2, pin: "4321")
    let (m4, K) = try tv.m4(ps.m3)
    let m5 = try ps.m5(m4: m4, name: "Test")
    let (m6, cid, ltpk) = try tv.m6(m5, K: K)
    let creds = try ps.credentials(m6: m6)
    #expect(creds.clientID == cid)
    #expect(Array(try Curve25519.Signing.PrivateKey(rawRepresentation: creds.clientSeed).publicKey.rawRepresentation) == ltpk)
    #expect(creds.serverID == tv.id)
    #expect(creds.serverPublicKey == Array(tv.ltsk.publicKey.rawRepresentation))
}

@Test func pairSetupWrongPinFailsAtM4() throws {
    let tv = FakeAccessory(pin: "4321")
    let ps = try PairSetup(m2: tv.m2, pin: "0000")
    // A real TV answers a wrong proof with error 2; a forged proof must not verify either.
    #expect(throws: ProtocolError.authentication("wrong PIN")) {
        try ps.m5(m4: TLV8.encode([(.state, [4]), (.error, [2])]), name: "x")
    }
    #expect(throws: ProtocolError.self) {
        try ps.m5(m4: TLV8.encode([(.state, [4]), (.proof, [UInt8](repeating: 1, count: 64))]), name: "x")
    }
}

@Test func pairVerifyAndSessionCipher() throws {
    let tvKey = Curve25519.Signing.PrivateKey()
    let tvID = Array("TV-1234".utf8)
    let clientKey = Curve25519.Signing.PrivateKey()
    let creds = Credentials(clientID: Array("client".utf8), clientSeed: Array(clientKey.rawRepresentation),
                            serverID: tvID, serverPublicKey: Array(tvKey.publicKey.rawRepresentation))
    var pv = PairVerify()

    // TV: M1 → M2
    let clientEph = try TLV8.decode(pv.m1)[.publicKey]!
    let tvEph = Curve25519.KeyAgreement.PrivateKey()
    let shared = try tvEph.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientEph))
    let key = hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
    let tvEphPub = Array(tvEph.publicKey.rawRepresentation)
    let sig = Array(try tvKey.signature(for: tvEphPub + tvID + clientEph))
    let inner = TLV8.encode([(.identifier, tvID), (.signature, sig)])
    let m2 = TLV8.encode([(.state, [2]), (.publicKey, tvEphPub), (.encryptedData, try seal(inner, key: key, nonce: "PV-Msg02"))])

    // Client: M3; TV checks the client's signature.
    let m3 = try pv.m3(m2: m2, credentials: creds)
    let m3inner = try TLV8.decode(try open(try TLV8.decode(m3)[.encryptedData]!, key: key, nonce: "PV-Msg03"))
    #expect(m3inner[.identifier] == creds.clientID)
    #expect(clientKey.publicKey.isValidSignature(m3inner[.signature]!, for: clientEph + creds.clientID + tvEphPub))

    // Session keys line up crosswise, and frames round-trip through two ciphers.
    let keys = try pv.sessionKeys(m4: TLV8.encode([(.state, [4])]))
    let tvSend = hkdf(shared, salt: "", info: "ServerEncrypt-main")
    let tvReceive = hkdf(shared, salt: "", info: "ClientEncrypt-main")
    #expect(keys.send.bytes == tvReceive.bytes && keys.receive.bytes == tvSend.bytes)
    var client = FrameCipher(send: keys.send, receive: keys.receive)
    var tv = FrameCipher(send: tvSend, receive: tvReceive)
    for n in 0..<3 {
        let header: [UInt8] = [8, 0, 0, UInt8(5 + n + 16)]
        let msg = [UInt8](repeating: UInt8(n), count: 5 + n)
        let sealed = client.seal(msg, header: header)
        #expect(try tv.open(sealed[...], header: header[...]) == msg)
        let back = tv.seal(msg, header: header)
        #expect(try client.open(back[...], header: header[...]) == msg)
    }
    // Wrong header (tampered length) must fail.
    let sealed = client.seal([1, 2, 3], header: [8, 0, 0, 19])
    #expect(throws: ProtocolError.self) { try tv.open(sealed[...], header: [8, 0, 0, 20][...]) }
}

@Test func pairVerifyRejectsImpostor() throws {
    let realKey = Curve25519.Signing.PrivateKey(), fakeKey = Curve25519.Signing.PrivateKey()
    let tvID = Array("TV".utf8)
    let creds = Credentials(clientID: [1], clientSeed: Array(Curve25519.Signing.PrivateKey().rawRepresentation),
                            serverID: tvID, serverPublicKey: Array(realKey.publicKey.rawRepresentation))
    var pv = PairVerify()
    let clientEph = try TLV8.decode(pv.m1)[.publicKey]!
    let tvEph = Curve25519.KeyAgreement.PrivateKey()
    let key = hkdf(try tvEph.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientEph)),
                   salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
    let pub = Array(tvEph.publicKey.rawRepresentation)
    let sig = Array(try fakeKey.signature(for: pub + tvID + clientEph))
    let m2 = TLV8.encode([(.state, [2]), (.publicKey, pub),
                          (.encryptedData, try seal(TLV8.encode([(.identifier, tvID), (.signature, sig)]), key: key, nonce: "PV-Msg02"))])
    #expect(throws: ProtocolError.self) { try pv.m3(m2: m2, credentials: creds) }
}

@Test func credentialStoreRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "remotetv-test-\(UInt32.random(in: 0...UInt32.max))")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "pairings.tsv")
    let a = Credentials(clientID: Array("A-ID".utf8), clientSeed: [UInt8](repeating: 1, count: 32), serverID: [9, 9],
                        serverPublicKey: [UInt8](repeating: 2, count: 32))
    let b = Credentials(clientID: Array("B-ID".utf8), clientSeed: [UInt8](repeating: 3, count: 32), serverID: [7],
                        serverPublicKey: [UInt8](repeating: 4, count: 32))
    var s = CredentialStore(url: url)
    #expect(s.entries.isEmpty)
    try s.save("Living Room", a)
    try s.save("Hotel\tTV", b)
    var t = CredentialStore(url: url)
    #expect(t.last == "Hotel TV")
    #expect(t.credentials(for: "Living Room") == a)
    try t.touch("Living Room")
    #expect(CredentialStore(url: url).last == "Living Room")
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}
