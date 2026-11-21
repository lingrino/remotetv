import CryptoKit

/// SRP-6a client for HAP pair-setup: 3072-bit group (RFC 5054), generator 5, SHA-512,
/// user "Pair-Setup", password = the PIN shown on the TV.
///
///   k = H(N | PAD(g))           x = H(s | H(I ":" P))       u = H(PAD(A) | PAD(B))
///   A = g^a                     S = (B − k·g^x)^(a + u·x)   K = H(PAD(S))
///   M1 = H(H(N) xor H(g) | H(I) | s | PAD(A) | PAD(B) | K)  M2 = H(PAD(A) | M1 | K)
///
/// All group elements are padded to 384 bytes, as Apple's HAP reference does; g is
/// hashed as the single byte 0x05 in M1.
struct SRPClient: Sendable {
    static let width = 384
    static let N = BigUInt(hex:
        "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" +
        "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" +
        "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" +
        "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" +
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" +
        "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" +
        "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" +
        "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff")!
    static let g = BigUInt(5)

    let publicKey: [UInt8]     // A, 384 bytes
    let proof: [UInt8]         // M1
    let sessionKey: [UInt8]    // K
    private let expectedServerProof: [UInt8]

    /// - Parameters:
    ///   - privateKey: a, random bytes (32 is plenty)
    init(username: String = "Pair-Setup", password: String, salt: [UInt8], serverPublicKey: [UInt8],
         privateKey: [UInt8]) throws(ProtocolError) {
        let N = SRPClient.N, g = SRPClient.g, w = SRPClient.width
        let mont = Montgomery(modulus: N)
        let B = BigUInt(bytes: serverPublicKey)
        guard BigUInt.compare(B, N) < 0, !B.isZero else { throw .authentication("invalid SRP public key") }
        let a = BigUInt(bytes: privateKey)

        let k = BigUInt(bytes: H(N.bytes(width: w), g.bytes(width: w)))
        let x = BigUInt(bytes: H(salt, H(Array(username.utf8) + [0x3A] + Array(password.utf8))))
        let A = mont.pow(g, a)
        let padA = A.bytes(width: w), padB = B.bytes(width: w)
        let u = BigUInt(bytes: H(padA, padB))
        guard !u.isZero else { throw .authentication("invalid SRP parameters") }

        let kv = mont.mulMod(k, mont.pow(g, x))
        let base = BigUInt.compare(B, kv) >= 0 ? B - kv : (B + N) - kv
        let S = mont.pow(base, a + u * x)
        let K = H(S.bytes(width: w))

        let hN = H(N.bytes(width: w)), hg = H([5])
        var hNg = [UInt8](repeating: 0, count: hN.count)
        for i in 0..<hN.count { hNg[i] = hN[i] ^ hg[i] }
        let M1 = H(hNg, H(Array(username.utf8)), salt, padA, padB, K)

        publicKey = padA
        proof = M1
        sessionKey = K
        expectedServerProof = H(padA, M1, K)
    }

    func verify(serverProof: [UInt8]) -> Bool {
        guard serverProof.count == expectedServerProof.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<serverProof.count { diff |= serverProof[i] ^ expectedServerProof[i] }
        return diff == 0
    }
}

/// SHA-512 over the concatenation of the parts.
func H(_ parts: [UInt8]...) -> [UInt8] {
    var h = SHA512()
    for p in parts { h.update(data: p) }
    return Array(h.finalize())
}
