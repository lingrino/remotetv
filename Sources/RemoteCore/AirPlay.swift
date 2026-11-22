import CryptoKit
import Foundation
import Network
import os

/// HAP transport encryption, as AirPlay uses it on every channel: the byte stream is cut
/// into frames of at most 1024 plaintext bytes, each sent as
/// `length (2, LE) | ChaCha20-Poly1305(frame) | tag (16)` with the length as AAD and a
/// per-direction counter as nonce (4 zero bytes, then the counter LE in 8).
struct HAPCipher {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var pending: [UInt8] = []

    init(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send
        receiveKey = receive
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        var c = counter
        for i in 4..<12 { n[i] = UInt8(truncatingIfNeeded: c); c >>= 8 }
        return try! ChaChaPoly.Nonce(data: n)
    }

    mutating func seal(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + (data.count / 1024 + 1) * 18)
        var i = 0
        repeat {
            let n = min(1024, data.count - i)
            let header: [UInt8] = [UInt8(n & 0xFF), UInt8(n >> 8)]
            let box = try! ChaChaPoly.seal(data[i..<(i + n)], using: sendKey, nonce: HAPCipher.nonce(sendCounter),
                                           authenticating: header)
            sendCounter &+= 1
            out += header
            out += box.ciphertext
            out += box.tag
            i += n
        } while i < data.count
        return out
    }

    /// Appends received bytes and returns whatever whole frames decrypt to.
    mutating func open(_ data: [UInt8]) throws(ProtocolError) -> [UInt8] {
        pending += data
        var out: [UInt8] = []
        var i = 0
        while pending.count - i >= 2 {
            let n = Int(pending[i]) | Int(pending[i + 1]) << 8
            guard pending.count - i >= 2 + n + 16 else { break }
            let header = pending[i..<(i + 2)]
            let body = pending[(i + 2)..<(i + 2 + n)], tag = pending[(i + 2 + n)..<(i + 2 + n + 16)]
            guard let box = try? ChaChaPoly.SealedBox(nonce: HAPCipher.nonce(receiveCounter), ciphertext: body, tag: tag),
                  let plain = try? ChaChaPoly.open(box, using: receiveKey, authenticating: header)
            else { throw .authentication("couldn't decrypt AirPlay data") }
            receiveCounter &+= 1
            out += plain
            i += 2 + n + 16
        }
        if i > 0 { pending.removeFirst(i) }
        return out
    }
}

/// A TCP connection carrying a byte stream, optionally HAP-encrypted. Main queue only.
@MainActor
final class HAPStream {
    private let nw: NWConnection
    private var cipher: HAPCipher?
    private var closed = false
    var onReady: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onClosed: ((ProtocolError?) -> Void)?

    isolated deinit { nw.cancel() }

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        // IPv4: the RTSP URI carries our address, and the TV's channel ports are reached
        // at its address; v4 keeps both simple (no scope ids).
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
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
        cipher = HAPCipher(send: send, receive: receive)
    }

    func send(_ bytes: [UInt8]) {
        guard !closed else { return }
        nw.send(content: cipher != nil ? cipher!.seal(bytes) : bytes, completion: .idempotent)
    }

    /// The TV's IPv4 address (to reach the channel ports) and ours (for the RTSP URI).
    var remoteHost: NWEndpoint.Host? {
        if case let .hostPort(host, _)? = nw.currentPath?.remoteEndpoint { return host }
        return nil
    }

    var localAddress: String? {
        if case let .hostPort(host, _)? = nw.currentPath?.localEndpoint, case let .ipv4(a) = host { return "\(a)" }
        return nil
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
            receive()
        case .failed(let e), .waiting(let e):
            finish(.connection("AirPlay: \(e.localizedDescription)"))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    var bytes = Array(data)
                    if self.cipher != nil {
                        do throws(ProtocolError) { bytes = try self.cipher!.open(bytes) } catch { return self.finish(error) }
                    }
                    if !bytes.isEmpty { self.onData?(bytes) }
                }
                if let error { self.finish(.connection("AirPlay: \(error.localizedDescription)")) }
                else if complete { self.finish(.connection("the Apple TV closed the AirPlay connection")) }
                else if !self.closed { self.receive() }
            }
        }
    }

    private func finish(_ e: ProtocolError?) {
        guard !closed else { return }
        cancel()
        onClosed?(e)
    }
}

/// An HTTP/RTSP message (request or response), enough for AirPlay's control and event
/// channels: start line, headers, Content-Length body.
struct HTTPMessage {
    var startLine: String
    var headers: [(String, String)]
    var body: [UInt8]

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// Status code of a response ("RTSP/1.0 200 OK" → 200).
    var status: Int? {
        let parts = startLine.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    func encoded() -> [UInt8] {
        var s = startLine + "\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(body.count)\r\n\r\n"
        return Array(s.utf8) + body
    }

    /// Removes and returns one complete message from the front of `buffer`.
    static func take(from buffer: inout [UInt8]) throws(ProtocolError) -> HTTPMessage? {
        guard let end = buffer.firstRange(of: [13, 10, 13, 10]) else {
            if buffer.count > 1 << 16 { throw .malformed("AirPlay header too long") }
            return nil
        }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst()
        var headers: [(String, String)] = []
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers.append((String(l[..<c]), l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)))
        }
        let length = Int(headers.first { $0.0.lowercased() == "content-length" }?.1 ?? "0") ?? 0
        guard length >= 0, length < 1 << 24 else { throw .malformed("AirPlay body length") }
        let bodyStart = end.upperBound
        guard buffer.count >= bodyStart + length else { return nil }
        let msg = HTTPMessage(startLine: start, headers: headers, body: Array(buffer[bodyStart..<(bodyStart + length)]))
        buffer.removeFirst(bodyStart + length)
        return msg
    }
}

/// The AirPlay 2 remote-control tunnel that carries MRP (MediaRemote) messages:
///
///   control (port from Bonjour `_airplay._tcp`): HTTP pair-verify with the Companion
///     credentials (the TV accepts the same pairing; no second PIN), then HAP-encrypted
///     RTSP: SETUP {isRemoteControlOnly} → eventPort, RECORD, SETUP {streams: [type 130]}
///     → dataPort; then `POST /feedback` every 2 s keeps the session alive.
///   events (eventPort): HAP-encrypted; the TV sends RTSP requests, we answer 200.
///   data (dataPort): HAP-encrypted data-stream frames (32-byte header + binary plist
///     {params: {data: varint-length-prefixed protobufs}}); "sync" frames get a "rply".
///
/// Nothing here is visible on the TV: a remote-control-only session plays no media.
@MainActor
public final class AirPlayTunnel {
    public enum State: Equatable, Sendable { case idle, connecting, ready, failed(String) }

    public let device: Device
    private let credentials: Credentials
    public private(set) var state: State = .idle { didSet { if state != oldValue { onState?(state) } } }
    public var onState: ((State) -> Void)?
    /// One serialized MRP ProtocolMessage.
    public var onMessage: (([UInt8]) -> Void)?
    /// Frame-level events, for debugging (`tvctl -v mrp`).
    public var onTrace: ((String) -> Void)?

    private static let log = Logger(subsystem: "com.lingrino.remotetv", category: "airplay")
    private var control: HAPStream?
    private var events: HAPStream?
    private var data: HAPStream?
    private var verify = PairVerify()
    private var controlBuffer: [UInt8] = []
    private var eventBuffer: [UInt8] = []
    private var dataBuffer: [UInt8] = []
    private var waiting: [(HTTPMessage) -> Void] = []
    /// When each waiting request was sent: a control channel that stops answering (6 s,
    /// three missed feedbacks) is torn down and the owner retries.
    private var waitingSince: [ContinuousClock.Instant] = []
    private var cseq = 0
    private let sessionID = UInt32.random(in: 1...UInt32.max)
    private let dacpID = String(UInt64.random(in: 1...UInt64.max), radix: 16, uppercase: true)
    private let activeRemote = UInt32.random(in: 1...UInt32.max)
    /// Our sync frames all carry one sequence number (as other clients do; the TV answers
    /// each with a "rply" regardless).
    private let sendSeqno = UInt64.random(in: 0x1_0000_0000..<0x1_FFFF_FFFF)
    private var feedback: Timer?
    private var timeout: DispatchWorkItem?
    /// Messages sent that the TV hasn't acknowledged yet (it answers each of our "sync"
    /// frames with a "rply"), and how many it has acknowledged on this connection: see
    /// `MediaRemote.unacknowledged`.
    private(set) var unacked = 0
    private(set) var acks = 0

    public init(device: Device, credentials: Credentials) {
        self.device = device
        self.credentials = credentials
    }

    public func connect() {
        guard state != .connecting && state != .ready else { return }
        teardown()
        state = .connecting
        verify = PairVerify()
        let c = HAPStream(endpoint: .service(name: device.name, type: "_airplay._tcp", domain: "local.", interface: nil))
        control = c
        c.onReady = { [weak self] in self?.pairVerify() }
        c.onData = { [weak self] bytes in self?.controlData(bytes) }
        c.onClosed = { [weak self] e in self?.fail(e ?? .connection("AirPlay closed")) }
        let t = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.state == .connecting { self?.fail(.timeout) } } }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: t)
        c.start()
    }

    public func disconnect() {
        teardown()
        state = .idle
    }

    /// Sends one serialized MRP ProtocolMessage.
    public func send(_ message: [UInt8]) {
        guard state == .ready, let data else { return }
        var payload: [UInt8] = []
        var n = message.count
        repeat {   // varint length prefix
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n > 0 { b |= 0x80 }
            payload.append(b)
        } while n > 0
        payload += message
        let plist = Plist.dict([("params", .dict([("data", .data(payload))]))]).encode()
        data.send(AirPlayTunnel.frame(type: "sync", command: "comm", seqno: sendSeqno, payload: plist))
        unacked += 1
        onTrace?("→ data frame \(plist.count + 32) B (message \(message.count) B)")
    }

    private func teardown() {
        timeout?.cancel()
        feedback?.invalidate()
        feedback = nil
        for s in [control, events, data] { s?.onClosed = nil; s?.cancel() }
        control = nil; events = nil; data = nil
        controlBuffer.removeAll(); eventBuffer.removeAll(); dataBuffer.removeAll()
        waiting.removeAll()
        waitingSince.removeAll()
        unacked = 0
        acks = 0
    }

    func fail(_ e: ProtocolError) {
        AirPlayTunnel.log.error("\(e.description, privacy: .public)")
        teardown()
        state = .failed(e.description)
    }

    // MARK: Control channel

    private func request(_ method: String, _ uri: String, proto: String = "RTSP/1.0", headers: [(String, String)] = [],
                         body: [UInt8] = [], reply: @escaping (HTTPMessage) -> Void) {
        guard let control else { return }
        var h: [(String, String)] = proto == "RTSP/1.0"
            ? [("CSeq", "\(cseq)"), ("DACP-ID", dacpID), ("Active-Remote", "\(activeRemote)"), ("Client-Instance", dacpID),
               ("User-Agent", "AirPlay/550.10")]
            : [("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"), ("X-Apple-HKP", "3")]
        cseq += 1
        h += headers
        waiting.append(reply)
        waitingSince.append(.now)
        control.send(HTTPMessage(startLine: "\(method) \(uri) \(proto)", headers: h, body: body).encoded())
    }

    private func controlData(_ bytes: [UInt8]) {
        controlBuffer += bytes
        onTrace?("← control \(String(decoding: bytes.prefix(40), as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | "))")
        do throws(ProtocolError) {
            while let msg = try HTTPMessage.take(from: &controlBuffer) {
                guard !waiting.isEmpty else { continue }
                waitingSince.removeFirst()
                waiting.removeFirst()(msg)
            }
        } catch {
            fail(error)
        }
    }

    private var uri: String { "rtsp://\(control?.localAddress ?? "0.0.0.0")/\(sessionID)" }

    private func pairVerify() {
        let octet = [("Content-Type", "application/octet-stream")]
        request("POST", "/pair-verify", proto: "HTTP/1.1", headers: octet, body: verify.m1) { [weak self] r in
            guard let self else { return }
            do {
                guard r.status == 200 else { throw ProtocolError.authentication("AirPlay pair-verify: HTTP \(r.status ?? 0)") }
                let m3 = try self.verify.m3(m2: r.body, credentials: self.credentials)
                self.request("POST", "/pair-verify", proto: "HTTP/1.1", headers: octet, body: m3) { [weak self] r in
                    guard let self else { return }
                    do {
                        guard r.status == 200 else { throw ProtocolError.authentication("AirPlay pair-verify: HTTP \(r.status ?? 0)") }
                        if !r.body.isEmpty { try self.verify.verify(m4: r.body) }
                        let k = try self.verify.keys(salt: "Control-Salt", send: "Control-Write-Encryption-Key",
                                                     receive: "Control-Read-Encryption-Key")
                        self.control?.enableEncryption(send: k.send, receive: k.receive)
                        self.setupEvents()
                    } catch let e as ProtocolError { self.fail(e) } catch { self.fail(.malformed("\(error)")) }
                }
            } catch let e as ProtocolError { self.fail(e) } catch { self.fail(.malformed("\(error)")) }
        }
    }

    private func setupPlist(_ p: Plist, then: @escaping (Plist) -> Void) {
        request("SETUP", uri, headers: [("Content-Type", "application/x-apple-binary-plist")], body: p.encode()) { [weak self] r in
            guard r.status == 200, let body = try? Plist.decode(r.body) else {
                self?.fail(.connection("AirPlay SETUP failed (\(r.status ?? 0))"))
                return
            }
            then(body)
        }
    }

    private func setupEvents() {
        setupPlist(.dict([
            ("isRemoteControlOnly", .bool(true)),
            ("osName", .string("iPhone OS")),
            ("sourceVersion", .string("550.10")),
            ("timingProtocol", .string("None")),
            ("model", .string("iPhone10,6")),
            ("deviceID", .string(Remote.pubID(credentials.clientSeed))),
            ("osVersion", .string("17.0")),
            ("osBuildVersion", .string("21A329")),
            ("macAddress", .string(Remote.pubID(credentials.clientSeed))),
            ("sessionUUID", .string(UUID().uuidString)),
            ("name", .string("RemoteTV")),
        ])) { [weak self] body in
            guard let self, let port = body["eventPort"]?.int, let host = self.control?.remoteHost else {
                self?.fail(.malformed("AirPlay SETUP: no event port"))
                return
            }
            self.openEvents(host, port)
        }
    }

    private func openEvents(_ host: NWEndpoint.Host, _ port: Int64) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return fail(.malformed("event port")) }
        let e = HAPStream(endpoint: .hostPort(host: host, port: p))
        events = e
        do throws(ProtocolError) {
            let k = try verify.keys(salt: "Events-Salt", send: "Events-Read-Encryption-Key", receive: "Events-Write-Encryption-Key")
            e.enableEncryption(send: k.send, receive: k.receive)
        } catch { return fail(error) }
        e.onData = { [weak self] bytes in self?.eventData(bytes) }
        e.onClosed = { [weak self] err in self?.fail(err ?? .connection("AirPlay events closed")) }
        e.onReady = { [weak self] in
            self?.request("RECORD", self?.uri ?? "") { [weak self] _ in self?.setupData(host) }
        }
        e.start()
    }

    /// The TV's requests on the event channel get a plain 200.
    private func eventData(_ bytes: [UInt8]) {
        eventBuffer += bytes
        onTrace?("← event bytes \(bytes.count)")
        do throws(ProtocolError) {
            while let req = try HTTPMessage.take(from: &eventBuffer) {
                var h: [(String, String)] = [("Audio-Latency", "0")]
                if let s = req.header("Server") { h.append(("Server", s)) }
                if let c = req.header("CSeq") { h.append(("CSeq", c)) }
                let proto = req.startLine.split(separator: " ").last.map(String.init) ?? "RTSP/1.0"
                events?.send(HTTPMessage(startLine: "\(proto) 200 OK", headers: h, body: []).encoded())
            }
        } catch {
            fail(error)
        }
    }

    private func setupData(_ host: NWEndpoint.Host) {
        let seed = UInt64.random(in: 0..<(1 << 62))
        setupPlist(.dict([("streams", .array([.dict([
            ("controlType", .int(2)),
            ("channelID", .string(UUID().uuidString)),
            ("seed", .int(Int64(seed))),
            ("clientUUID", .string(UUID().uuidString)),
            ("type", .int(130)),
            ("wantsDedicatedSocket", .bool(true)),
            ("clientTypeUUID", .string("1910A70F-DBC0-4242-AF95-115DB30604E1")),
        ])]))])) { [weak self] body in
            guard let self, case .array(let streams)? = body["streams"], let port = streams.first?["dataPort"]?.int,
                  let p = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port))
            else { self?.fail(.malformed("AirPlay SETUP: no data port")); return }
            let d = HAPStream(endpoint: .hostPort(host: host, port: p))
            self.data = d
            do throws(ProtocolError) {
                let k = try self.verify.keys(salt: "DataStream-Salt\(seed)", send: "DataStream-Output-Encryption-Key",
                                             receive: "DataStream-Input-Encryption-Key")
                d.enableEncryption(send: k.send, receive: k.receive)
            } catch { return self.fail(error) }
            d.onData = { [weak self] bytes in self?.streamData(bytes) }
            d.onClosed = { [weak self] err in self?.fail(err ?? .connection("AirPlay data stream closed")) }
            d.onReady = { [weak self] in self?.ready() }
            d.start()
        }
    }

    private func ready() {
        timeout?.cancel()
        state = .ready
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let oldest = self.waitingSince.first, ContinuousClock.now - oldest > .seconds(6) {
                    return self.fail(.connection("AirPlay stopped responding"))
                }
                self.request("POST", "/feedback") { _ in }
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        feedback = t
    }

    // MARK: Data stream

    /// 32-byte header: total size (4, BE) | type (12: "sync"/"rply" + zeros) |
    /// command (4: "comm" or zeros) | seqno (8, BE) | padding (4).
    nonisolated static func frame(type: String, command: String?, seqno: UInt64, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(32 + payload.count)
        let size = UInt32(32 + payload.count)
        for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: size >> UInt32(s))) }
        out += Array(type.utf8) + [UInt8](repeating: 0, count: 12 - type.utf8.count)
        out += command.map { Array($0.utf8) } ?? [0, 0, 0, 0]
        for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: seqno >> UInt64(s))) }
        out += [0, 0, 0, 0]
        return out + payload
    }

    private func streamData(_ bytes: [UInt8]) {
        dataBuffer += bytes
        while dataBuffer.count >= 32 {
            let size = Int(dataBuffer[0]) << 24 | Int(dataBuffer[1]) << 16 | Int(dataBuffer[2]) << 8 | Int(dataBuffer[3])
            guard size >= 32, size < 1 << 24 else { return fail(.malformed("data stream frame size")) }
            guard dataBuffer.count >= size else { break }
            let isSync = dataBuffer[4..<8].elementsEqual("sync".utf8)   // type follows the 4-byte size
            let isReply = dataBuffer[4..<8].elementsEqual("rply".utf8)
            var seqno: UInt64 = 0
            for i in 20..<28 { seqno = seqno << 8 | UInt64(dataBuffer[i]) }
            let payload = Array(dataBuffer[32..<size])
            dataBuffer.removeFirst(size)
            onTrace?("← data frame \(isSync ? "sync" : isReply ? "rply" : "other") \(size) B")
            if isSync { data?.send(AirPlayTunnel.frame(type: "rply", command: nil, seqno: seqno, payload: [])) }
            if isReply {
                acks += 1
                if unacked > 0 { unacked -= 1 }
            }
            if !payload.isEmpty, onTrace != nil { onTrace?("  payload \((try? Plist.decode(payload)).map { "\($0)" }?.prefix(300) ?? "not a plist")") }
            guard !payload.isEmpty, let p = try? Plist.decode(payload), let blob = p["params"]?["data"]?.data else { continue }
            var i = 0
            while i < blob.count {
                if blob[i] == 0x08 {   // a bare message without a length prefix
                    onMessage?(Array(blob[i...]))
                    break
                }
                var n = 0, shift = 0
                while i < blob.count {
                    let b = blob[i]; i += 1
                    n |= Int(b & 0x7F) << shift
                    shift += 7
                    if b & 0x80 == 0 || shift > 28 { break }
                }
                guard n > 0, i + n <= blob.count else { break }
                onMessage?(Array(blob[i..<(i + n)]))
                i += n
            }
        }
    }
}
