import Foundation
import Network
import os

/// Liveness and recovery: unanswered-press watchdog, probes, reconnect, goodbye, wake knock.
/// See AGENTS.md "Reliability".
extension Remote {
    // MARK: - Reliability

    /// A TV can keep the TCP connection while its remote service stops answering (seen by
    /// other clients after hours). Presses and probes are tracked; one unanswered for 3 s
    /// drops the session, discards queued presses (replaying them late would be worse than
    /// losing them) and lets the owner reconnect.
    static var deafAfter: Duration = .seconds(3)

    func track(_ x: Int) {
        awaiting[x] = .now
        if deafCheck == nil { scheduleDeafCheck() }
    }

    func scheduleDeafCheck() {
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkDeaf() } }
        deafCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func checkDeaf() {
        deafCheck = nil
        guard case .session = phase, let oldest = awaiting.values.min() else {
            awaiting.removeAll()
            return
        }
        if ContinuousClock.now - oldest > Remote.deafAfter {
            Remote.log.error("\(self.device.name, privacy: .public): stopped answering; reconnecting")
            queued.removeAll()
            closed(.connection("the Apple TV stopped responding"))
            return
        }
        scheduleDeafCheck()
    }

    /// Checks a session that's been quiet for a while (the window came forward): a cheap
    /// request that must be answered, so a dead session is found before the user presses.
    /// Not connected: connects.
    public func probe(force: Bool = false) {
        switch phase {
        case .session:
            guard force || ContinuousClock.now - lastAnswer > .seconds(15) else { return }
            request("FetchMediaControlStatus", count: 0, { _ in }) { [weak self] reply in self?.controlsAnswer(reply) }
        case .idle:
            if isPaired { connect() }
        default:
            break
        }
    }

    /// Drops the connection and makes a new one now (network changed, Mac woke).
    public func reconnect() {
        guard isPaired else { return }
        switch phase {
        case .pairStart, .pinEntry, .pairM3, .pairM5: return   // never interrupt pairing
        default: break
        }
        teardown()
        status = .idle
        connect()
    }

    /// Closes the session the way Apple's remote does (`_sessionStop`), then disconnects.
    /// `done` runs once the goodbye is on the wire (or right away when not connected).
    public func goodbye(then done: @escaping @MainActor () -> Void = {}) {
        guard case .session = phase else {
            disconnect()
            return done()
        }
        var finished = false
        let finish: @MainActor () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.disconnect()
            done()
        }
        let s = sid
        send("_sessionStop", type: 2, count: 2, { w in
            w.string("_srvT"); w.string("com.apple.tvremoteservices")
            w.string("_sid"); w.uint(s)
        }, reply: nil, then: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { finish() } }
    }

    /// Wakes a TV whose address is known but that can't be reached: a sleeping Apple TV's
    /// Bonjour records live on in a sleep proxy, which wakes it when someone connects to
    /// one of its ports. Brief connection attempts, at most every 10 s.
    func knock() {
        guard let host = lastHost, ContinuousClock.now - lastKnock > .seconds(10) else { return }
        lastKnock = .now
        for port: UInt16 in [49153, 7000, 3689, 49152, 32498] {
            let c = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            c.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { c.cancel() }
        }
    }
}
