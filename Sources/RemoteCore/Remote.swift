import CryptoKit
import Foundation
import Network
import os

/// Companion HID usages: the Siri Remote's buttons (`_hidC`).
public enum Button: Int, Sendable, CaseIterable {
    case up = 1, down = 2, left = 3, right = 4
    case menu = 5          // "Back"
    case select = 6
    case home = 7          // TV / Control Center button
    case volumeUp = 8, volumeDown = 9
    case siri = 10
    case screensaver = 11
    case sleep = 12, wake = 13
    case playPause = 14
    case channelUp = 15, channelDown = 16
    case guide = 17
    case pageUp = 18, pageDown = 19
}

extension Button {
    /// Lowercase names for scripting ("playpause", "volumeup", "back" = menu, "tv" = home).
    public static func named(_ name: String) -> Button? {
        switch name.lowercased() {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "select", "ok": .select
        case "menu", "back": .menu
        case "home", "tv": .home
        case "volumeup": .volumeUp
        case "volumedown": .volumeDown
        case "playpause", "play", "pause": .playPause
        case "siri": .siri
        case "screensaver": .screensaver
        case "guide": .guide
        case "pageup": .pageUp
        case "pagedown": .pageDown
        case "channelup": .channelUp
        case "channeldown": .channelDown
        default: nil
        }
    }
}

public enum PowerState: Sendable, Equatable {
    case unknown, asleep, awake
}

/// What the TV says it can do right now (`_iMC` media-control flags).
public struct MediaControls: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let play = MediaControls(rawValue: 0x0001)
    public static let pause = MediaControls(rawValue: 0x0002)
    public static let next = MediaControls(rawValue: 0x0004)
    public static let previous = MediaControls(rawValue: 0x0008)
    public static let volume = MediaControls(rawValue: 0x0100)
    public static let skipForward = MediaControls(rawValue: 0x0200)
    public static let skipBackward = MediaControls(rawValue: 0x0400)
}

/// A remote control session with one Apple TV over Companion Link.
///
/// Lifecycle: `connect()` → TCP → pair-verify with the stored credentials → encrypted →
/// handshake (`_systemInfo`, `_sessionStart`, …, fired without waiting) → `.connected`.
/// Without credentials, `pair()` runs pair-setup instead: the TV shows a PIN, the user
/// types it into `submitPIN`, and on success `onPaired` hands out credentials to store,
/// then the session reconnects with them.
///
/// Commands sent while (re)connecting are queued and flushed once connected, so a key
/// press right after launch or wake isn't lost. Main-thread only.
@MainActor
public final class Remote {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        /// Pair-setup started: the TV shows a 4-digit PIN.
        case waitingForPIN
        case pairing
        case connected
        case failed(ProtocolError)
        /// Pair-verify was refused: the TV no longer knows these credentials (reset,
        /// removed under Remotes and Devices). Retrying can't help; pair again.
        case unpaired

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public let device: Device
    public internal(set) var credentials: Credentials?
    public internal(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            Remote.log.info("\(self.device.name, privacy: .public): \(String(describing: self.status), privacy: .public)")
            onStatus?(status)
        }
    }
    public internal(set) var power: PowerState = .unknown { didSet { if power != oldValue { onPower?(power) } } }
    public internal(set) var controls: MediaControls = []
    /// False until the TV has said which controls work (then dimming applies).
    public internal(set) var controlsKnown = false
    /// What's playing (nil: nothing, or not known yet).
    public internal(set) var nowPlaying: NowPlaying?
    /// The TV's focused text field, if any.
    public internal(set) var textSession: TextSession?

    public var onStatus: ((Status) -> Void)?
    public var onPower: ((PowerState) -> Void)?
    public var onPaired: ((Credentials) -> Void)?
    /// The TV focused (session) or left (nil) a text field.
    public var onTextSession: ((TextSession?) -> Void)?
    public var onNowPlaying: ((NowPlaying?) -> Void)?
    /// Media-control flags changed (`controls`).
    public var onControls: ((MediaControls) -> Void)?
    /// Connect → pair-verify done → handshake sent, for latency logging.
    public var onTiming: ((String, Duration) -> Void)?
    /// Every message sent (→) and received (←), decoded, for debugging (`tvctl -v`).
    public var onTrace: ((String) -> Void)?
    /// Every message received, decoded (exploration tools).
    public var onMessage: ((OPACK.Value) -> Void)?

    /// How we introduce ourselves (`_systemInfo`, pairing name shown in the TV's settings).
    public var clientName = "RemoteTV"

    static let log = Logger(subsystem: "com.lingrino.remotetv", category: "remote")

    enum Phase {
        case idle
        case connecting
        case verifying(PairVerify)
        case pairStart
        case pinEntry(m2: [UInt8])
        case pairM3(PairSetup)
        case pairM5(PairSetup)
        case session
    }

    var phase: Phase = .idle
    var conn: Connection?
    var xid = Int.random(in: 0..<0x8000)
    var replies: [Int: (OPACK.Value) -> Void] = [:]
    /// `raw` requests on the wire, by xid. Every one completes exactly once: its reply, the
    /// connection ending, or 5 s (`Waiter`).
    var rawReplies: [Int: Waiter] = [:]
    /// Commands waiting for a connection. Each runs only if it's at most `queueMaxAge`
    /// old when the session comes up: a press replayed late is worse than a lost one.
    var queued: [(at: ContinuousClock.Instant, run: () -> Void)] = []
    static var queueMaxAge: Duration = .seconds(2)
    /// How long a `raw` request may wait for its answer.
    static var rawTimeout: Double = 5
    /// Bumped per pairing attempt; stale SRP results are dropped.
    var attempt = 0
    var timeout: DispatchWorkItem?
    var sid: UInt64 = 0
    var started = ContinuousClock.now

    // Liveness (see "Reliability" below).
    var awaiting: [Int: ContinuousClock.Instant] = [:]
    var deafCheck: DispatchWorkItem?
    var keepalive: Timer?
    var lastAnswer = ContinuousClock.now
    var lastKnock = ContinuousClock.now - .seconds(60)
    /// Failed connects since the last session (knocking stops after a few: away from home
    /// the remembered address belongs to someone else's network).
    var failStreak = 0
    /// Where the TV was last reached; knocked on to wake it when it can't be found.
    public internal(set) var lastHost: NWEndpoint.Host?

    public init(device: Device, credentials: Credentials?) {
        self.device = device
        self.credentials = credentials
        if let h = UserDefaults.standard.string(forKey: "host.\(device.name)") { lastHost = NWEndpoint.Host(h) }
    }

    public var isPaired: Bool { credentials != nil }

    // MARK: - Lifecycle

    /// Connects with the stored credentials. No-op while connected or connecting.
    public func connect() {
        guard credentials != nil else { status = .failed(.authentication("not paired")); return }
        switch phase {
        case .idle: break
        default: return
        }
        open { [weak self] in
            guard let self else { return }
            let pv = PairVerify()
            self.phase = .verifying(pv)
            self.sendAuth(.pairVerifyStart, pv.m1, extra: ("_auTy", 4))
        }
    }

    public func disconnect() {
        queued.removeAll()
        teardown()
        status = .idle
    }

    /// Starts pair-setup: the TV shows a PIN. Replaces any credentials once it succeeds.
    public func pair() {
        teardown()
        attempt &+= 1
        open { [weak self] in
            guard let self else { return }
            self.phase = .pairStart
            self.sendAuth(.pairSetupStart, PairSetup.m1(), extra: ("_pwTy", 1))
        }
    }

    /// The PIN from the TV screen, after `pair()` reached `.waitingForPIN`.
    public func submitPIN(_ pin: String) {
        guard case .pinEntry(let m2) = phase else { return }
        status = .pairing
        phase = .connecting   // nothing else may move the state machine while SRP runs
        let token = attempt
        Task.detached(priority: .userInitiated) {
            let result: Result<(PairSetup, [UInt8]), ProtocolError>
            do throws(ProtocolError) {
                let ps = try PairSetup(m2: m2, pin: pin)
                result = .success((ps, ps.m3))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                // The connection may have closed (or another attempt started) during SRP.
                guard let self, self.attempt == token, self.conn != nil, case .connecting = self.phase else { return }
                switch result {
                case .success(let (ps, m3)):
                    self.phase = .pairM3(ps)
                    self.sendAuth(.pairSetupNext, m3, extra: ("_pwTy", 1))
                    self.armTimeout(10)
                case .failure(let e):
                    self.fail(e)
                }
            }
        }
    }

    func open(then: @escaping () -> Void) {
        teardown()
        status = .connecting
        phase = .connecting
        started = .now
        let c = Connection(endpoint: device.endpoint)
        conn = c
        c.onEvent = { [weak self, weak c] event in
            guard let self, let c, c === self.conn else { return }
            switch event {
            case .ready:
                self.onTiming?("tcp", ContinuousClock.now - self.started)
                then()
            case .frame(let type, let payload):
                self.received(type, payload)
            case .closed(let err):
                self.closed(err)
            }
        }
        armTimeout(8)
        c.start()
    }

    func teardown() {
        stopMedia()
        timeout?.cancel()
        timeout = nil
        awaiting.removeAll()
        deafCheck?.cancel()
        deafCheck = nil
        keepalive?.invalidate()
        keepalive = nil
        conn?.onEvent = nil
        conn?.cancel()
        conn = nil
        phase = .idle
        replies.removeAll()
        // Requests sent on this connection will never be answered now.
        let lost = rawReplies.values
        rawReplies.removeAll()
        for w in lost { w.finish(nil, "disconnected") }
    }

    /// A connect or pairing step failed. Queued commands stay (they expire by age), so a
    /// press made while the TV wakes still lands after the quick retry.
    func fail(_ e: ProtocolError) {
        Remote.log.error("\(self.device.name, privacy: .public): \(e.description, privacy: .public)")
        teardown()
        failStreak += 1
        switch e {
        case .timeout, .connection, .notFound: if failStreak <= 3 { knock() }
        default: break
        }
        status = .failed(e)
    }

    func closed(_ err: ProtocolError?) {
        let wasSession = if case .session = phase { true } else { false }
        teardown()
        if wasSession {
            // Dropped while in use (TV slept, network blip): the owner reconnects.
            status = .failed(err ?? .connection("disconnected"))
        } else {
            fail(err ?? .connection("the Apple TV closed the connection"))
        }
    }

    func armTimeout(_ seconds: Double) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fail(.timeout) }
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Pairing frames

    func sendAuth(_ type: FrameType, _ tlv: [UInt8], extra: (String, Int)?) {
        var w = OPACK.Writer()
        w.dict(extra == nil ? 1 : 2)
        w.string("_pd")
        w.data(tlv)
        if let (k, v) = extra { w.string(k); w.int(v) }
        conn?.send(type, w.bytes)
    }

    func received(_ type: FrameType, _ payload: [UInt8]) {
        let msg: OPACK.Value
        do { msg = try OPACK.decode(payload) } catch {
            // In a session, one message we can't read (a future tvOS tag) is dropped, not
            // fatal: failing would reconnect into the same message forever.
            if case .session = phase {
                Remote.log.notice("dropped an unreadable message: \(error.description, privacy: .public)")
                return
            }
            return fail(error)
        }
        switch type {
        case .pairSetupNext, .pairVerifyNext:
            switch phase {
            case .verifying, .pairStart, .pairM3, .pairM5: break
            default: return   // not expecting pairing: ignore rather than fail
            }
            guard let pd = msg["_pd"]?.data else { return fail(.malformed("pairing reply without _pd")) }
            do { try auth(pd) } catch { fail(error) }
        case .encryptedOPACK, .unencryptedOPACK, .packedOPACK:
            // Only once pair-verify has authenticated the TV and the frames are encrypted:
            // before that, anything on the LAN answering for the TV's name could inject.
            guard case .session = phase, conn?.isEncrypted == true else { return }
            message(msg)
        default:
            break
        }
    }

    func auth(_ pd: [UInt8]) throws(ProtocolError) {
        switch phase {
        case .verifying(var pv):
            // Error 2 (authentication) means the TV no longer knows us; other codes (busy,
            // back off) are passing: fail and retry as usual.
            if let code = try TLV8.decode(pd)[.error]?.first {
                guard code == 2 else { throw .authentication(TLV8.errorDescription(code)) }
                Remote.log.error("\(self.device.name, privacy: .public): pair-verify refused: pairing lost")
                queued.removeAll()
                teardown()
                status = .unpaired
                return
            }
            if try TLV8.decode(pd)[.state] == [2], let creds = credentials {
                let m3 = try pv.m3(m2: pd, credentials: creds)
                phase = .verifying(pv)
                sendAuth(.pairVerifyNext, m3, extra: nil)
            } else {
                let keys = try pv.sessionKeys(m4: pd)
                conn?.enableEncryption(send: keys.send, receive: keys.receive)
                onTiming?("verified", ContinuousClock.now - started)
                startSession()
            }
        case .pairStart:
            _ = try PairSetup.check(pd, state: 2)
            timeout?.cancel()
            phase = .pinEntry(m2: pd)
            status = .waitingForPIN
        case .pairM3(let ps):
            let m5 = try ps.m5(m4: pd, name: clientName)
            phase = .pairM5(ps)
            sendAuth(.pairSetupNext, m5, extra: ("_pwTy", 1))
            armTimeout(10)
        case .pairM5(let ps):
            let creds = try ps.credentials(m6: pd)
            credentials = creds
            onPaired?(creds)
            teardown()
            connect()
        default:
            throw .malformed("unexpected pairing message")
        }
    }

    // MARK: - Session

    func startSession() {
        timeout?.cancel()
        phase = .session
        let local = UInt64.random(in: 1...UInt64(UInt32.max))
        let creds = credentials!
        let id = String(decoding: creds.clientID, as: UTF8.self)
        let hex = id.lowercased().filter { $0.isHexDigit }
        request("_systemInfo", count: 10) { w in
            w.string("_bf"); w.int(0)
            w.string("_cf"); w.int(512)
            w.string("_clFl"); w.int(128)
            // A stable "_i" is what makes the TV push power-state events to us.
            w.string("_i"); w.string(String(hex.prefix(12)))
            w.string("_idsID"); w.string(id)
            w.string("_pubID"); w.string(Remote.pubID(creds.clientSeed))
            w.string("_sf"); w.int(256)
            w.string("_sv"); w.string("170.18")
            w.string("model"); w.string("iPhone10,6")
            w.string("name"); w.string(self.clientName)
        }
        request("_touchStart", count: 3) { w in
            w.string("_height"); w.double(1000)
            w.string("_tFl"); w.int(0)
            w.string("_width"); w.double(1000)
        }
        request("_sessionStart", count: 2, { w in
            w.string("_srvT"); w.string("com.apple.tvremoteservices")
            w.string("_sid"); w.int(Int64(local))
        }) { [weak self] reply in
            if let remote = reply["_c"]?["_sid"]?.int { self?.sid = UInt64(UInt32(truncatingIfNeeded: remote)) << 32 | local }
        }
        // tvOS answers FetchAttentionState only after a TV Remote session is registered.
        request("TVRCSessionStart", count: 1) { w in
            w.string("ProtocolVersionKey"); w.string("1.2")
        }
        // Text input: the reply carries the session if a text field is already focused
        // (then no _tiStarted follows).
        request("_tiStart", count: 0, { _ in }) { [weak self] reply in
            self?.setTextSession(reply["_c"]?["_tiD"]?.data.flatMap(TextSession.init(archive:)))
        }
        event("_interest", count: 1) { w in
            let events = ["_iMC", "SystemStatus", "TVSystemStatus", "_tiStarted", "_tiStopped", "NowPlayingInfo"]
            w.string("_regEvents"); w.array(events.count)
            for e in events { w.string(e) }
        }
        request("FetchAttentionState", count: 0, { _ in }) { [weak self] reply in
            if let s = reply["_c"]?["state"]?.int { self?.systemStatus(s) }
        }
        // The answer comes as a NowPlayingInfo event.
        request("FetchCurrentNowPlayingInfoEvent", count: 0) { _ in }
        status = .connected
        onTiming?("session", ContinuousClock.now - started)
        lastAnswer = .now
        failStreak = 0
        if let h = conn?.remoteHost {
            lastHost = h
            UserDefaults.standard.set("\(h)", forKey: "host.\(device.name)")
        }
        let k = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.conn?.send(.noOp, []) }
        }
        k.tolerance = 5
        RunLoop.main.add(k, forMode: .common)
        keepalive = k
        startMedia()
        let pending = queued
        queued.removeAll()
        let now = ContinuousClock.now
        for q in pending where now - q.at <= Remote.queueMaxAge { q.run() }
    }

    func message(_ msg: OPACK.Value) {
        onTrace?("← \(msg)")
        onMessage?(msg)
        switch msg["_t"]?.int {
        case 1:   // event
            let content = msg["_c"]
            switch msg["_i"]?.string {
            case "SystemStatus", "TVSystemStatus":
                if let s = content?["state"]?.int { systemStatus(s) }
            case "_iMC":
                if let f = content?["_mcF"]?.int, Int(f) != controls.rawValue || !controlsKnown {
                    controls = MediaControls(rawValue: Int(f))
                    controlsKnown = true
                    onControls?(controls)
                }
            case "NowPlayingInfo":
                companionPlaying = content?["NowPlayingInfoKey"]?.data.flatMap(NowPlaying.init(archive:))
                publishNowPlaying()
            case "_tiStarted":
                setTextSession(content?["_tiD"]?.data.flatMap(TextSession.init(archive:)))
            case "_tiStopped":
                setTextSession(nil)
            default:
                break
            }
        case 3:   // response
            guard let x = msg["_x"]?.int else { return }
            awaiting.removeValue(forKey: Int(x))
            lastAnswer = .now
            let handler = replies.removeValue(forKey: Int(x))
            // Errors: `_em` (message) and/or `_ec`/`_ed` (code, domain; -6714 = not handled).
            let error: String? = msg["_em"]?.string ?? msg["_ec"]?.int.map { "\(msg["_ed"]?.string ?? "error") \($0)" }
            if let raw = rawReplies.removeValue(forKey: Int(x)) {
                raw.finish(error == nil ? msg : nil, error)
                return
            }
            if let error {
                Remote.log.notice("request failed: \(error, privacy: .public)")
                return
            }
            handler?(msg)
        default:
            break
        }
    }

    func setTextSession(_ s: TextSession?) {
        guard s != textSession else { return }
        textSession = s
        onTextSession?(s)
    }

    func systemStatus(_ s: Int64) {
        // 1 asleep, 2 screensaver, 3 awake, 4 idle
        power = s == 1 ? .asleep : (s >= 2 && s <= 4 ? .awake : .unknown)
    }

    /// Writes `{_i, _t, _c: {count pairs}, _x}` and sends it encrypted.
    func send(_ identifier: String, type: Int, count: Int, _ content: (inout OPACK.Writer) -> Void,
                      reply: ((OPACK.Value) -> Void)?, registered: ((Int) -> Void)? = nil,
                      then done: (@MainActor () -> Void)? = nil) {
        guard let conn else { return }
        var w = OPACK.Writer(capacity: 96)
        w.dict(4)
        w.string("_i"); w.string(identifier)
        w.string("_t"); w.int(type)
        w.string("_c"); w.dict(count); content(&w); if count >= 15 { w.end() }
        let x = xid
        xid = (xid + 1) & 0x7FFF_FFFF
        w.string("_x"); w.int(x)
        if let reply { replies[x] = reply }
        registered?(x)
        if type == 2 && (identifier == "_hidC" || identifier == "FetchMediaControlStatus") { track(x) }
        if let onTrace { onTrace("→ \((try? OPACK.decode(w.bytes)).map { "\($0)" } ?? "?")") }
        if let done { conn.send(.encryptedOPACK, w.bytes, then: done) } else { conn.send(.encryptedOPACK, w.bytes) }
    }

    func request(_ id: String, count: Int, _ content: (inout OPACK.Writer) -> Void,
                         reply: ((OPACK.Value) -> Void)? = nil) {
        send(id, type: 2, count: count, content, reply: reply)
    }

    func event(_ id: String, count: Int, _ content: (inout OPACK.Writer) -> Void) {
        send(id, type: 1, count: count, content, reply: nil)
    }

    /// Runs `f` now if connected, else after the (re)connect that this starts (if it's
    /// still young then). `release` commands (a button's "up") are always kept, so a full
    /// queue can never strand a held button on the TV.
    func whenConnected(release: Bool = false, _ f: @escaping () -> Void) {
        if case .session = phase { f(); return }
        if release || queued.count < 16 { queued.append((ContinuousClock.now, f)) }
        switch phase {
        case .idle where isPaired: connect()
        default: break
        }
    }

    /// The TV wants a MAC-address-like public id; derive a stable one from our *public*
    /// key (nothing derived from the private seed leaves the Mac).
    static func pubID(_ seed: [UInt8]) -> String {
        let pub = (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed))?.publicKey.rawRepresentation
        let h = H(Array(pub ?? Data()))
        return h.prefix(6).map { b in
            let s = String(b, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: ":")
    }

    // MARK: - MRP state (Remote+Media.swift)

    /// Started with every session; a failure never affects the remote (buttons, text,
    /// Companion now playing keep working) and is retried quietly with backoff.
    var media: MediaRemote?

    var mediaRetry: DispatchWorkItem?

    var mediaFailures = 0

    var companionPlaying: NowPlaying?

    /// MRP ready / not (mute availability, now-playing source).
    public var onMediaReady: ((Bool) -> Void)?

    /// Ask for now-playing artwork (MRP) while something shows it.
    public var wantsArtwork = false {
        didSet { media?.wantsArtwork = wantsArtwork }
    }

}
