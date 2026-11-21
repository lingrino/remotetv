import CryptoKit
import Foundation
import Network

/// Companion frame types (first header byte).
public enum FrameType: UInt8, Sendable {
    case noOp = 1
    case pairSetupStart = 3
    case pairSetupNext = 4
    case pairVerifyStart = 5
    case pairVerifyNext = 6
    case unencryptedOPACK = 7
    case encryptedOPACK = 8
    case packedOPACK = 9
}

/// Companion session encryption: ChaCha20-Poly1305 per frame with the 4-byte frame header
/// as associated data and a per-direction counter as nonce (little-endian, in the first
/// 8 of 12 bytes).
struct FrameCipher {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send
        receiveKey = receive
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        var c = counter
        for i in 0..<8 { n[i] = UInt8(truncatingIfNeeded: c); c >>= 8 }
        return try! ChaChaPoly.Nonce(data: n)
    }

    /// Ciphertext + tag for `payload`, authenticated with `header`.
    mutating func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8] {
        let box = try! ChaChaPoly.seal(payload, using: sendKey, nonce: FrameCipher.nonce(sendCounter), authenticating: header)
        sendCounter &+= 1
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 16)
        out.append(contentsOf: box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }

    mutating func open(_ sealed: ArraySlice<UInt8>, header: ArraySlice<UInt8>) throws(ProtocolError) -> [UInt8] {
        guard sealed.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: FrameCipher.nonce(receiveCounter),
                                                  ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: receiveKey, authenticating: header)
        else { throw .authentication("couldn't decrypt a frame from the Apple TV") }
        receiveCounter &+= 1
        return Array(plain)
    }
}

/// One TCP connection to an Apple TV's Companion port: framing (type, 24-bit big-endian
/// length, payload) and, once pair-verify is done, encryption. Main-thread only; the
/// network callbacks are delivered on the main queue, so a key press goes from the event
/// to `send` (encrypt + hand to the kernel) in one synchronous step.
@MainActor
final class Connection {
    enum Event {
        case ready
        case frame(FrameType, [UInt8])
        case closed(ProtocolError?)
    }

    private let nw: NWConnection
    private var buffer: [UInt8] = []
    private var cipher: FrameCipher?
    private var closed = false
    var onEvent: ((Event) -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                 // a button press is two tiny frames: never wait for Nagle
        tcp.enableKeepalive = true         // notice a TV that went away (sleep, network change)
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        params.serviceClass = .responsiveData
        nw = NWConnection(to: endpoint, using: params)
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }
        nw.start(queue: .main)
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        nw.stateUpdateHandler = nil
        nw.cancel()
    }

    func enableEncryption(send: SymmetricKey, receive: SymmetricKey) {
        cipher = FrameCipher(send: send, receive: receive)
    }

    var isEncrypted: Bool { cipher != nil }

    func send(_ type: FrameType, _ payload: [UInt8]) {
        guard !closed else { return }
        let length = payload.count + (cipher != nil && !payload.isEmpty ? 16 : 0)
        var frame: [UInt8] = [type.rawValue, UInt8(truncatingIfNeeded: length >> 16),
                              UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)]
        frame.reserveCapacity(4 + length)
        if cipher != nil && !payload.isEmpty {
            frame.append(contentsOf: cipher!.seal(payload, header: frame))
        } else {
            frame.append(contentsOf: payload)
        }
        nw.send(content: frame, completion: .idempotent)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onEvent?(.ready)
            receive()
        case .failed(let err):
            finish(.connection(Connection.describe(err)))
        case .waiting(let err):
            // No route/refused: report instead of letting Network retry forever; the
            // owner decides when to try again.
            finish(.connection(Connection.describe(err)))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(contentsOf: data)
                    self.parse()
                }
                if let error {
                    self.finish(.connection(Connection.describe(error)))
                } else if isComplete {
                    self.finish(.connection("the Apple TV closed the connection"))
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func parse() {
        var i = 0
        while buffer.count - i >= 4 {
            let length = Int(buffer[i + 1]) << 16 | Int(buffer[i + 2]) << 8 | Int(buffer[i + 3])
            guard buffer.count - i - 4 >= length else { break }
            let header = buffer[i..<(i + 4)]
            let body = buffer[(i + 4)..<(i + 4 + length)]
            let raw = buffer[i]
            i += 4 + length
            guard let type = FrameType(rawValue: raw) else { continue }
            var payload: [UInt8]
            if cipher != nil && !body.isEmpty {
                do {
                    payload = try cipher!.open(body, header: header)
                } catch {
                    finish(error)
                    return
                }
            } else {
                payload = Array(body)
            }
            onEvent?(.frame(type, payload))
            if closed { return }
        }
        if i > 0 { buffer.removeFirst(i) }
    }

    private func finish(_ error: ProtocolError?) {
        guard !closed else { return }
        cancel()
        onEvent?(.closed(error))
    }

    private static func describe(_ e: NWError) -> String {
        switch e {
        case .posix(let code) where code == .ECONNREFUSED: "the Apple TV refused the connection"
        case .posix(let code) where code == .ETIMEDOUT: "the Apple TV didn't answer"
        case .posix(let code) where code == .ENETDOWN || code == .ENETUNREACH || code == .EHOSTUNREACH:
            "the Apple TV isn't reachable"
        case .dns(let code) where code == -65570:   // kDNSServiceErr_PolicyDenied
            "Local Network access is off for RemoteTV (System Settings → Privacy & Security)"
        case .dns: "couldn't find the Apple TV on the network"
        default: e.localizedDescription
        }
    }
}
