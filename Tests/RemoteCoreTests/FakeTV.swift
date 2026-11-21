import CryptoKit
import Foundation
import Network
@testable import RemoteCore

/// A loopback Apple TV for testing `Remote`: a TCP listener on 127.0.0.1 speaking Companion
/// framing, the TV's side of pair-verify (with a known identity), then encrypted OPACK.
/// Requests are answered with an empty `_c` unless a test says otherwise.
@MainActor
final class FakeTV {
    let tvKey = Curve25519.Signing.PrivateKey()
    let tvID = Array("FAKE-TV".utf8)
    let clientKey = Curve25519.Signing.PrivateKey()
    let clientID = Array("client-1".utf8)

    /// Session messages received (decrypted, decoded).
    private(set) var received: [OPACK.Value] = []
    /// Answer requests (`_t` 2)? Per identifier: false = stay silent.
    var answers: [String: Bool] = [:]
    /// Sent right after accepting, before pair-verify: an injection attempt.
    var preAuthFrame: (FrameType, [UInt8])?
    /// Pair-verify M2 is this error TLV instead (2 = the pairing is unknown).
    var verifyError: UInt8?
    /// Delay before answering pair-verify M1.
    var verifyDelay: Double = 0

    private var listener: NWListener!
    private var conn: NWConnection?
    private var buffer: [UInt8] = []
    private var cipher: FrameCipher?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var shared: SharedSecret?
    private(set) var port: UInt16 = 0

    var credentials: Credentials {
        Credentials(clientID: clientID, clientSeed: Array(clientKey.rawRepresentation), serverID: tvID,
                    serverPublicKey: Array(tvKey.publicKey.rawRepresentation))
    }

    var device: Device {
        Device(name: "fake-\(port)", model: "AppleTV", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.accept(c) } }
        l.start(queue: .main)
        for _ in 0..<400 {
            if let p = l.port, p.rawValue != 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        port = l.port?.rawValue ?? 0

    }

    func stop() {
        conn?.cancel()
        listener?.cancel()
    }

    /// Drops the current connection (the TV went away).
    func drop() {
        conn?.cancel()
        conn = nil
        cipher = nil
        buffer.removeAll()
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        cipher = nil
        buffer.removeAll()
        c.start(queue: .main)
        if let (t, p) = preAuthFrame { sendFrame(t, p) }
        receive()
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer += data; self.parse() }
                if !done && error == nil { self.receive() }
            }
        }
    }

    private func parse() {
        while buffer.count >= 4 {
            let n = Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + n else { return }
            let header = Array(buffer[0..<4]), body = Array(buffer[4..<(4 + n)])
            buffer.removeFirst(4 + n)
            var payload = body
            if cipher != nil && !body.isEmpty {
                guard let p = try? cipher!.open(body[...], header: header[...]) else { return }
                payload = p
            }
            frame(FrameType(rawValue: header[0]), payload)
        }
    }

    private func frame(_ type: FrameType?, _ payload: [UInt8]) {
        guard let type, let msg = try? OPACK.decode(payload) else { return }
        switch type {
        case .pairVerifyStart:
            let reply = { [self] in
                if let e = verifyError {
                    return sendPairing(TLV8.encode([(.state, [2]), (.error, [e])]))
                }
                let clientEph = try! TLV8.decode(msg["_pd"]!.data!)[.publicKey]!
                let eph = Curve25519.KeyAgreement.PrivateKey()
                ephemeral = eph
                shared = try! eph.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientEph))
                let key = hkdf(shared!, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
                let pub = Array(eph.publicKey.rawRepresentation)
                let sig = Array(try! tvKey.signature(for: pub + tvID + clientEph))
                let inner = TLV8.encode([(.identifier, tvID), (.signature, sig)])
                sendPairing(TLV8.encode([(.state, [2]), (.publicKey, pub),
                                         (.encryptedData, try! seal(inner, key: key, nonce: "PV-Msg02"))]))
            }
            if verifyDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) { MainActor.assumeIsolated { reply() } }
            } else {
                reply()
            }
        case .pairVerifyNext:
            sendPairing(TLV8.encode([(.state, [4])]))
            cipher = FrameCipher(send: hkdf(shared!, salt: "", info: "ServerEncrypt-main"),
                                 receive: hkdf(shared!, salt: "", info: "ClientEncrypt-main"))
        case .encryptedOPACK:
            received.append(msg)
            if msg["_t"]?.int == 2, let id = msg["_i"]?.string, answers[id] ?? true, let x = msg["_x"]?.int {
                send(.dict(["_t": .int(3), "_x": .int(x), "_c": .dict([:])]))
            }
        default:
            break
        }
    }

    private func sendPairing(_ tlv: [UInt8]) {
        sendFrame(.pairVerifyNext, OPACK.encode(.dict(["_pd": .data(tlv)])))
    }

    /// An encrypted session message (or plaintext, before the session).
    func send(_ msg: OPACK.Value) {
        sendFrame(.encryptedOPACK, OPACK.encode(msg))
    }

    func sendRaw(_ payload: [UInt8]) { sendFrame(.encryptedOPACK, payload) }

    private func sendFrame(_ type: FrameType, _ payload: [UInt8]) {
        let length = payload.count + (cipher != nil && !payload.isEmpty ? 16 : 0)
        var f: [UInt8] = [type.rawValue, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        if cipher != nil && !payload.isEmpty { f += cipher!.seal(payload, header: f) } else { f += payload }
        conn?.send(content: f, completion: .idempotent)
    }

    /// The `_hidC` presses received, as (button, down).
    var presses: [(Int64, Bool)] {
        received.compactMap { m in
            guard m["_i"]?.string == "_hidC", let b = m["_c"]?["_hidC"]?.int, let s = m["_c"]?["_hBtS"]?.int else { return nil }
            return (b, s == 1)
        }
    }
}

/// Polls (letting the main queue run) until `ok` or the deadline.
@MainActor
func eventually(_ seconds: Double = 3, _ ok: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if ok() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return ok()
}
