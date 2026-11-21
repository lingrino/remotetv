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
        case failed(String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public let device: Device
    public private(set) var credentials: Credentials?
    public private(set) var status: Status = .idle { didSet { if status != oldValue { onStatus?(status) } } }
    public private(set) var power: PowerState = .unknown { didSet { if power != oldValue { onPower?(power) } } }
    public private(set) var controls: MediaControls = []

    public var onStatus: ((Status) -> Void)?
    public var onPower: ((PowerState) -> Void)?
    public var onPaired: ((Credentials) -> Void)?
    /// The TV opened (true) or closed (false) a text field.
    public var onTextInput: ((Bool) -> Void)?
    /// Connect → pair-verify done → handshake sent, for latency logging.
    public var onTiming: ((String, Duration) -> Void)?

    /// How we introduce ourselves (`_systemInfo`, pairing name shown in the TV's settings).
    public var clientName = "RemoteTV"

    private static let log = Logger(subsystem: "com.lingrino.remotetv", category: "remote")

    private enum Phase {
        case idle
        case connecting
        case verifying(PairVerify)
        case pairStart
        case pinEntry(m2: [UInt8])
        case pairM3(PairSetup)
        case pairM5(PairSetup)
        case session
    }

    private var phase: Phase = .idle
    private var conn: Connection?
    private var xid = Int.random(in: 0..<0x8000)
    private var replies: [Int: (OPACK.Value) -> Void] = [:]
    private var queued: [() -> Void] = []
    private var timeout: DispatchWorkItem?
    private var sid: UInt64 = 0
    private var started = ContinuousClock.now

    public init(device: Device, credentials: Credentials?) {
        self.device = device
        self.credentials = credentials
    }

    public var isPaired: Bool { credentials != nil }

    // MARK: - Lifecycle

    /// Connects with the stored credentials. No-op while connected or connecting.
    public func connect() {
        guard credentials != nil else { status = .failed("not paired"); return }
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
        teardown()
        status = .idle
    }

    /// Starts pair-setup: the TV shows a PIN. Replaces any credentials once it succeeds.
    public func pair() {
        teardown()
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
        Task.detached(priority: .userInitiated) {
            let result: Result<(PairSetup, [UInt8]), ProtocolError>
            do throws(ProtocolError) {
                let ps = try PairSetup(m2: m2, pin: pin)
                result = .success((ps, ps.m3))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let (ps, m3)):
                    self.phase = .pairM3(ps)
                    self.sendAuth(.pairSetupNext, m3, extra: ("_pwTy", 1))
                case .failure(let e):
                    self.fail(e)
                }
            }
        }
    }

    private func open(then: @escaping () -> Void) {
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

    private func teardown() {
        timeout?.cancel()
        timeout = nil
        conn?.onEvent = nil
        conn?.cancel()
        conn = nil
        phase = .idle
        replies.removeAll()
    }

    private func fail(_ e: ProtocolError) {
        Remote.log.error("\(self.device.name, privacy: .public): \(e.description, privacy: .public)")
        queued.removeAll()
        teardown()
        status = .failed(e.description)
    }

    private func closed(_ err: ProtocolError?) {
        let wasSession = if case .session = phase { true } else { false }
        teardown()
        if wasSession {
            // Dropped while in use (TV slept, network blip): the owner reconnects.
            status = .failed(err?.description ?? "disconnected")
        } else {
            fail(err ?? .connection("the Apple TV closed the connection"))
        }
    }

    private func armTimeout(_ seconds: Double) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fail(.timeout) }
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Pairing frames

    private func sendAuth(_ type: FrameType, _ tlv: [UInt8], extra: (String, Int)?) {
        var w = OPACK.Writer()
        w.dict(extra == nil ? 1 : 2)
        w.string("_pd")
        w.data(tlv)
        if let (k, v) = extra { w.string(k); w.int(v) }
        conn?.send(type, w.bytes)
    }

    private func received(_ type: FrameType, _ payload: [UInt8]) {
        let msg: OPACK.Value
        do { msg = try OPACK.decode(payload) } catch { return fail(error) }
        switch type {
        case .pairSetupNext, .pairVerifyNext:
            guard let pd = msg["_pd"]?.data else { return fail(.malformed("pairing reply without _pd")) }
            do { try auth(pd) } catch { fail(error) }
        case .encryptedOPACK, .unencryptedOPACK, .packedOPACK:
            message(msg)
        default:
            break
        }
    }

    private func auth(_ pd: [UInt8]) throws(ProtocolError) {
        switch phase {
        case .verifying(var pv):
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

    private func startSession() {
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
            if let remote = reply["_c"]?["_sid"]?.int { self?.sid = UInt64(remote) << 32 | local }
        }
        // tvOS answers FetchAttentionState only after a TV Remote session is registered.
        request("TVRCSessionStart", count: 1) { w in
            w.string("ProtocolVersionKey"); w.string("1.2")
        }
        event("_interest", count: 1) { w in
            let events = ["_iMC", "SystemStatus", "TVSystemStatus", "_tiStarted", "_tiStopped"]
            w.string("_regEvents"); w.array(events.count)
            for e in events { w.string(e) }
        }
        request("FetchAttentionState", count: 0, { _ in }) { [weak self] reply in
            if let s = reply["_c"]?["state"]?.int { self?.systemStatus(s) }
        }
        status = .connected
        onTiming?("session", ContinuousClock.now - started)
        let pending = queued
        queued.removeAll()
        for f in pending { f() }
    }

    private func message(_ msg: OPACK.Value) {
        switch msg["_t"]?.int {
        case 1:   // event
            let content = msg["_c"]
            switch msg["_i"]?.string {
            case "SystemStatus", "TVSystemStatus":
                if let s = content?["state"]?.int { systemStatus(s) }
            case "_iMC":
                if let f = content?["_mcF"]?.int { controls = MediaControls(rawValue: Int(f)) }
            case "_tiStarted":
                onTextInput?(true)
            case "_tiStopped":
                onTextInput?(false)
            default:
                break
            }
        case 3:   // response
            guard let x = msg["_x"]?.int else { return }
            let handler = replies.removeValue(forKey: Int(x))
            if let em = msg["_em"]?.string {
                Remote.log.notice("request failed: \(em, privacy: .public)")
                return
            }
            handler?(msg)
        default:
            break
        }
    }

    private func systemStatus(_ s: Int64) {
        // 1 asleep, 2 screensaver, 3 awake, 4 idle
        power = s == 1 ? .asleep : (s >= 2 && s <= 4 ? .awake : .unknown)
    }

    /// Writes `{_i, _t, _c: {count pairs}, _x}` and sends it encrypted.
    private func send(_ identifier: String, type: Int, count: Int, _ content: (inout OPACK.Writer) -> Void,
                      reply: ((OPACK.Value) -> Void)?) {
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
        conn.send(.encryptedOPACK, w.bytes)
    }

    private func request(_ id: String, count: Int, _ content: (inout OPACK.Writer) -> Void,
                         reply: ((OPACK.Value) -> Void)? = nil) {
        send(id, type: 2, count: count, content, reply: reply)
    }

    private func event(_ id: String, count: Int, _ content: (inout OPACK.Writer) -> Void) {
        send(id, type: 1, count: count, content, reply: nil)
    }

    /// Runs `f` now if connected, else after the (re)connect that this starts.
    private func whenConnected(_ f: @escaping () -> Void) {
        if case .session = phase { f(); return }
        if queued.count < 16 { queued.append(f) }
        if case .idle = phase, isPaired { connect() }
    }

    /// The TV wants a MAC-address-like public id; derive a stable one from our key.
    static func pubID(_ seed: [UInt8]) -> String {
        let h = H(seed)
        return h.prefix(6).map { b in
            let s = String(b, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: ":")
    }

    // MARK: - Commands

    /// Button down or up. Holding a button (down … up) behaves like holding the Siri
    /// Remote's: scrolling repeats, long-press menus open.
    public func button(_ b: Button, down: Bool) {
        whenConnected { [weak self] in
            self?.request("_hidC", count: 2) { w in
                w.string("_hBtS"); w.int(down ? 1 : 2)
                w.string("_hidC"); w.int(b.rawValue)
            }
        }
    }

    /// A click: down then up.
    public func press(_ b: Button) {
        button(b, down: true)
        button(b, down: false)
    }

    /// Skips playback by `seconds` (negative = back).
    public func skip(_ seconds: Double) {
        whenConnected { [weak self] in
            self?.request("_mcc", count: 2) { w in
                w.string("_mcc"); w.int(7)
                w.string("_skpS"); w.double(seconds)
            }
        }
    }

    public func wake() {
        whenConnected { [weak self] in
            self?.request("_hidC", count: 2) { w in
                w.string("_hBtS"); w.int(2)
                w.string("_hidC"); w.int(Button.wake.rawValue)
            }
        }
        power = .awake
    }

    public func sleep() {
        whenConnected { [weak self] in
            self?.request("_hidC", count: 2) { w in
                w.string("_hBtS"); w.int(2)
                w.string("_hidC"); w.int(Button.sleep.rawValue)
            }
        }
        power = .asleep
    }

    public func togglePower() {
        if power == .asleep { wake() } else { sleep() }
    }

    public func launch(bundleID: String) {
        whenConnected { [weak self] in
            self?.request("_launchApp", count: 1) { w in
                w.string("_bundleID"); w.string(bundleID)
            }
        }
    }

    /// Touch surface (1000×1000): phase 1 press, 3 hold/move, 4 release, 5 click.
    public func touch(x: Double, y: Double, phase: Int) {
        guard case .session = self.phase else { return }
        let (sec, atto) = (ContinuousClock.now - started).components
        let ns = sec * 1_000_000_000 + atto / 1_000_000_000
        event("_hidT", count: 5) { w in
            w.string("_ns"); w.int(max(0, ns))
            w.string("_tFg"); w.int(1)
            w.string("_cx"); w.int(Int64(min(1000, max(0, x))))
            w.string("_tPh"); w.int(phase)
            w.string("_cy"); w.int(Int64(min(1000, max(0, y))))
        }
    }
}
