import CryptoKit
import Foundation

/// What a successful pairing leaves behind: our long-term Ed25519 identity and the TV's.
/// Pair-verify needs all four on every connect. Persisted by `CredentialStore`.
public struct Credentials: Sendable, Equatable {
    /// Our pairing identifier (a UUID string, as bytes), registered on the TV.
    public var clientID: [UInt8]
    /// Our Ed25519 private key seed (32 bytes).
    public var clientSeed: [UInt8]
    /// The TV's pairing identifier.
    public var serverID: [UInt8]
    /// The TV's Ed25519 public key (32 bytes).
    public var serverPublicKey: [UInt8]

    public init(clientID: [UInt8], clientSeed: [UInt8], serverID: [UInt8], serverPublicKey: [UInt8]) {
        self.clientID = clientID
        self.clientSeed = clientSeed
        self.serverID = serverID
        self.serverPublicKey = serverPublicKey
    }
}

/// HAP pair-setup (M1…M6), the one-time PIN pairing. Pure message logic: the caller moves
/// the TLV8 payloads over the wire (Companion wraps each in an OPACK `{_pd, _pwTy}`).
///
///   M1 → method 0, state 1                       (the TV shows a PIN)
///   M2 ← salt, B
///   M3 → A, M1 proof                             (SRP with the PIN; CPU-heavy)
///   M4 ← M2 proof
///   M5 → Enc(K: id, LTPK, sig(iOSDeviceX | id | LTPK), name)
///   M6 ← Enc(K: TV id, TV LTPK, TV sig)
struct PairSetup: Sendable {
    static func m1() -> [UInt8] {
        TLV8.encode([(.method, [0x00]), (.state, [0x01])])
    }

    let clientID: [UInt8]
    let signingKey: Curve25519.Signing.PrivateKey
    private let srp: SRPClient
    private let encryptKey: SymmetricKey

    /// Runs SRP for M2 + PIN. Takes ~10 ms in release builds: call off the main thread.
    init(m2: [UInt8], pin: String, clientID: [UInt8] = Array(UUID().uuidString.utf8),
         signingKey: Curve25519.Signing.PrivateKey = .init(),
         srpPrivateKey: [UInt8] = PairSetup.random(32)) throws(ProtocolError) {
        let items = try PairSetup.check(m2, state: 2)
        guard let salt = items[.salt], let B = items[.publicKey] else { throw .malformed("pair-setup M2") }
        srp = try SRPClient(password: pin, salt: salt, serverPublicKey: B, privateKey: srpPrivateKey)
        self.clientID = clientID
        self.signingKey = signingKey
        encryptKey = hkdf(srp.sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
    }

    var m3: [UInt8] {
        TLV8.encode([(.state, [0x03]), (.publicKey, srp.publicKey), (.proof, srp.proof)])
    }

    /// Checks the TV's SRP proof (M4) and builds M5. A wrong PIN fails here (the TV sends
    /// error 2 instead of a proof).
    func m5(m4: [UInt8], name: String) throws(ProtocolError) -> [UInt8] {
        let items = try PairSetup.check(m4, state: 4)
        guard let proof = items[.proof], srp.verify(serverProof: proof) else {
            throw .authentication("the Apple TV's proof didn't match")
        }
        let x = hkdf(srp.sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let ltpk = Array(signingKey.publicKey.rawRepresentation)
        let signature: [UInt8]
        do {
            signature = Array(try signingKey.signature(for: x.bytes + clientID + ltpk))
        } catch {
            throw .authentication("signing failed")
        }
        var info = OPACK.Writer()
        info.dict(1)
        info.string("name")
        info.string(name)
        let inner = TLV8.encode([(.identifier, clientID), (.publicKey, ltpk), (.signature, signature), (.name, info.bytes)])
        let sealed = try seal(inner, key: encryptKey, nonce: "PS-Msg05")
        return TLV8.encode([(.state, [0x05]), (.encryptedData, sealed)])
    }

    /// Decrypts M6 into the credentials to keep.
    func credentials(m6: [UInt8]) throws(ProtocolError) -> Credentials {
        let items = try PairSetup.check(m6, state: 6)
        guard let encrypted = items[.encryptedData] else { throw .malformed("pair-setup M6") }
        let inner = try TLV8.decode(try open(encrypted, key: encryptKey, nonce: "PS-Msg06"))
        guard let id = inner[.identifier], let ltpk = inner[.publicKey], ltpk.count == 32 else {
            throw .malformed("pair-setup M6 contents")
        }
        // M6 is already authenticated by the SRP session key (only the TV that showed
        // the PIN can produce it); the Ed25519 signature is a second check, required to
        // verify when present. The key must be a valid Ed25519 key either way: pair-verify
        // depends on it.
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: ltpk) else {
            throw .authentication("the Apple TV sent an invalid key")
        }
        if let sig = inner[.signature] {
            let x = hkdf(srp.sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            guard pub.isValidSignature(sig, for: x.bytes + id + ltpk) else {
                throw .authentication("the Apple TV's signature didn't verify")
            }
        }
        return Credentials(clientID: clientID, clientSeed: Array(signingKey.rawRepresentation),
                           serverID: id, serverPublicKey: ltpk)
    }

    /// Decodes a pairing reply, turning a HAP error TLV into a readable error.
    static func check(_ tlv: [UInt8], state: UInt8) throws(ProtocolError) -> TLV8.Items {
        let items = try TLV8.decode(tlv)
        if let err = items[.error]?.first { throw .authentication(TLV8.errorDescription(err)) }
        guard items[.state] == [state] else { throw .malformed("pairing state \(items[.state] ?? []) ≠ \(state)") }
        return items
    }

    static func random(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
}

/// HAP pair-verify (M1…M4), run on every connect with stored credentials. Proves both
/// long-term identities over a fresh X25519 exchange and yields the session keys.
///
///   M1 → state 1, our ephemeral X25519 key
///   M2 ← TV ephemeral key, Enc(TV id, sig(TVeph | TVid | ourEph))
///   M3 → Enc(our id, sig(ourEph | ourID | TVeph))
///   M4 ← state 4 (or error)
struct PairVerify {
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var shared: SharedSecret?

    init() {}

    var m1: [UInt8] {
        TLV8.encode([(.state, [0x01]), (.publicKey, Array(ephemeral.publicKey.rawRepresentation))])
    }

    mutating func m3(m2: [UInt8], credentials c: Credentials) throws(ProtocolError) -> [UInt8] {
        let items = try PairSetup.check(m2, state: 2)
        guard let serverEph = items[.publicKey], let encrypted = items[.encryptedData],
              let serverKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverEph),
              let secret = try? ephemeral.sharedSecretFromKeyAgreement(with: serverKey)
        else { throw .malformed("pair-verify M2") }
        shared = secret
        let key = hkdf(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let inner = try TLV8.decode(try open(encrypted, key: key, nonce: "PV-Msg02"))
        guard let id = inner[.identifier], let sig = inner[.signature] else { throw .malformed("pair-verify M2 contents") }
        guard id == c.serverID else { throw .authentication("this isn't the Apple TV we paired with") }
        let ourEph = Array(ephemeral.publicKey.rawRepresentation)
        guard let tvKey = try? Curve25519.Signing.PublicKey(rawRepresentation: c.serverPublicKey),
              tvKey.isValidSignature(sig, for: serverEph + id + ourEph)
        else { throw .authentication("the Apple TV's signature didn't verify; pair again") }
        guard let ours = try? Curve25519.Signing.PrivateKey(rawRepresentation: c.clientSeed),
              let mySig = try? ours.signature(for: ourEph + c.clientID + serverEph)
        else { throw .authentication("stored credentials are damaged; pair again") }
        let reply = TLV8.encode([(.identifier, c.clientID), (.signature, Array(mySig))])
        return TLV8.encode([(.state, [0x03]), (.encryptedData, try seal(reply, key: key, nonce: "PV-Msg03"))])
    }

    /// Checks M4 and returns the Companion session keys (send, receive).
    func sessionKeys(m4: [UInt8]) throws(ProtocolError) -> (send: SymmetricKey, receive: SymmetricKey) {
        try verify(m4: m4)
        return try keys(salt: "", send: "ClientEncrypt-main", receive: "ServerEncrypt-main")
    }

    /// Checks M4 (the TV accepted our M3).
    func verify(m4: [UInt8]) throws(ProtocolError) {
        _ = try PairSetup.check(m4, state: 4)
    }

    /// Keys for a channel secured by this verify: HKDF-SHA512 over the shared secret.
    /// AirPlay derives one pair per channel (control, events, data stream).
    func keys(salt: String, send: String, receive: String) throws(ProtocolError) -> (send: SymmetricKey, receive: SymmetricKey) {
        guard let shared else { throw .malformed("pair-verify out of order") }
        return (hkdf(shared, salt: salt, info: send), hkdf(shared, salt: salt, info: receive))
    }
}

// MARK: - Crypto helpers

func hkdf(_ input: [UInt8], salt: String, info: String) -> SymmetricKey {
    HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), salt: Array(salt.utf8),
                           info: Array(info.utf8), outputByteCount: 32)
}

func hkdf(_ input: SharedSecret, salt: String, info: String) -> SymmetricKey {
    input.hkdfDerivedSymmetricKey(using: SHA512.self, salt: Array(salt.utf8), sharedInfo: Array(info.utf8),
                                  outputByteCount: 32)
}

/// ChaCha20-Poly1305 with a pairing nonce: the ASCII label right-aligned in 12 bytes.
private func labelNonce(_ label: String) -> ChaChaPoly.Nonce {
    let l = Array(label.utf8)
    return try! ChaChaPoly.Nonce(data: [UInt8](repeating: 0, count: 12 - l.count) + l)
}

/// Ciphertext followed by the 16-byte tag.
func seal(_ plain: [UInt8], key: SymmetricKey, nonce: String) throws(ProtocolError) -> [UInt8] {
    guard let box = try? ChaChaPoly.seal(plain, using: key, nonce: labelNonce(nonce)) else {
        throw .authentication("encryption failed")
    }
    return Array(box.ciphertext) + Array(box.tag)
}

func open(_ sealed: [UInt8], key: SymmetricKey, nonce: String) throws(ProtocolError) -> [UInt8] {
    guard sealed.count >= 16,
          let box = try? ChaChaPoly.SealedBox(nonce: labelNonce(nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)),
          let plain = try? ChaChaPoly.open(box, using: key)
    else { throw .authentication("decryption failed") }
    return Array(plain)
}

extension SymmetricKey {
    var bytes: [UInt8] { withUnsafeBytes { Array($0) } }
}
