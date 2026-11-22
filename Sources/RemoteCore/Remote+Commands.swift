import Foundation
import Network
import os

/// What the remote can do: buttons, playback, text, power, apps, touch, raw requests.
extension Remote {
    // MARK: - Commands

    /// Any request, for exploring the protocol (`tvctl raw`). The reply (or nil on `_em`
    /// error) goes to `reply` with the error text.
    /// The reply always comes, exactly once: the TV's answer, (nil, error) when it answered
    /// with one, the connection ended, or 5 s passed (also while still waiting to connect).
    public func raw(_ id: String, _ content: [String: OPACK.Value], event: Bool = false,
                    reply: ((OPACK.Value?, String?) -> Void)? = nil) {
        let waiter = reply.map(Waiter.init)
        if let waiter {
            DispatchQueue.main.asyncAfter(deadline: .now() + Remote.rawTimeout) { [weak self, weak waiter] in
                MainActor.assumeIsolated {
                    guard let waiter, !waiter.finished else { return }
                    if let self, let x = self.rawReplies.first(where: { $0.value === waiter })?.key { self.rawReplies[x] = nil }
                    waiter.finish(nil, "timed out")
                }
            }
        }
        whenConnected { [weak self] in
            guard let self else { return }
            guard waiter?.finished != true else { return }   // timed out while queued
            self.send(id, type: event ? 1 : 2, count: content.count, { w in
                for k in content.keys.sorted() { w.string(k); w.value(content[k]!) }
            }, reply: nil, registered: { x in if let waiter { self.rawReplies[x] = waiter } })
            self.onTrace?("→ \(id) \(content)")
        }
    }

    /// One pending `raw` reply.
    final class Waiter {
        let reply: (OPACK.Value?, String?) -> Void
        private(set) var finished = false
        init(_ reply: @escaping (OPACK.Value?, String?) -> Void) { self.reply = reply }
        func finish(_ value: OPACK.Value?, _ error: String?) {
            guard !finished else { return }
            finished = true
            reply(value, error)
        }
    }

    /// Button down or up. Holding a button (down … up) behaves like holding the Siri
    /// Remote's: scrolling repeats, long-press menus open.
    public func button(_ b: Button, down: Bool) {
        whenConnected(release: !down) { [weak self] in self?.hid(b, down: down) }
    }

    /// A click: down then up, queued as one unit (never half a press).
    public func press(_ b: Button) {
        whenConnected { [weak self] in
            self?.hid(b, down: true)
            self?.hid(b, down: false)
        }
    }

    func hid(_ b: Button, down: Bool) {
        request("_hidC", count: 2) { w in
            w.string("_hBtS"); w.int(down ? 1 : 2)
            w.string("_hidC"); w.int(b.rawValue)
        }
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

    /// Jumps to `seconds` into the playing item (as a relative skip from the current
    /// extrapolated position; Companion has no absolute seek).
    public func seek(to seconds: Double) {
        if let m = media, m.isReady, m.supports(45) {
            m.seek(to: seconds)
            return
        }
        guard let np = nowPlaying else { return }
        let delta = seconds - np.position()
        guard abs(delta) >= 0.5 else { return }
        skip(delta)
        // Show the new position right away; the TV's own snapshot follows.
        var moved = np
        moved.elapsed = max(0, seconds)
        moved.timestamp = Date().timeIntervalSinceReferenceDate
        companionPlaying = moved
        publishNowPlaying()
    }

    /// Mute toggle (HID Mute key over MRP); needs the AirPlay tunnel (`muteAvailable`).
    public func toggleMute() {
        media?.toggleMute()
    }

    public var muteAvailable: Bool { media?.isReady == true }


    /// Whether the scrubber can move playback: MRP absolute seek, or Companion skips (the
    /// TV's flags; assumed yes until it has said).
    public var canSeek: Bool {
        if let m = media, m.isReady, m.supports(45) { return true }
        return !controlsKnown || controls.contains(.skipForward) || controls.contains(.skipBackward)
    }

    public func refreshNowPlaying() {
        guard case .session = phase else { return }
        media?.refresh()
        request("FetchCurrentNowPlayingInfoEvent", count: 0) { _ in }
    }

    /// Subtitles on/off for the playing item: Companion `ToggleCaptions`, which is what
    /// Apple's own remote sends. (MRP EnableLanguageOption looked cleaner but replaced the
    /// item's whole media selection on the owner's TV: audio went silent. Don't use it.)
    /// The resulting state shows up through now playing (MRP language options when the
    /// app publishes them, else Companion's flags).
    public func toggleCaptions() {
        whenConnected { [weak self] in
            self?.request("ToggleCaptions", count: 0) { _ in
                // The TV doesn't always push a new snapshot after a toggle: ask.
                self?.refreshNowPlaying()
            }
        }
    }

    /// Edits the focused TV text field: `delete` characters before the cursor, then type
    /// `insert`. See `RTI.diff` for turning a local field change into an edit.
    public func editText(delete: Int, insert: String) {
        guard delete > 0 || !insert.isEmpty else { return }
        sendText(textSession.map { RTI.edit(session: $0.uuid, delete: delete, insert: insert) })
    }

    /// Replaces the focused TV text field's whole contents.
    public func setText(_ text: String) {
        sendText(textSession.map { RTI.replace(session: $0.uuid, with: text) })
    }

    func sendText(_ ops: [UInt8]?) {
        guard let ops, case .session = phase else { return }
        event("_tiC", count: 2) { w in
            w.string("_tiV"); w.int(1)
            w.string("_tiD"); w.data(ops)
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

    // MARK: - Connect, act, leave (tvctl without the app)

    /// What a command may need to have heard from the TV before it runs. Each level
    /// includes the ones before it.
    public enum Knowledge: Sendable {
        /// The session is up: buttons, skips, launches, requests.
        case session
        /// The handshake's answers are in: power state, the focused text field.
        case state
        /// The AirPlay link is up (mute), or won't be.
        case link
        /// What's playing is known (or nothing is).
        case playing
    }

    /// How long `knows` waits for each kind of answer before going with what there is.
    static var knowledgeWait: (state: Duration, link: Duration, playing: Duration) =
        (.seconds(1), .seconds(2), .milliseconds(250))

    /// Whether the session has heard that much. `.connected` only means the handshake was
    /// sent: its answers, the AirPlay link (~130 ms) and the first now-playing state follow.
    /// A session that has been up for a while knows everything; one made for a single
    /// command has to wait for what that command reads. Every wait is bounded
    /// (`knowledgeWait`): a TV that doesn't say counts as nothing to know.
    public func knows(_ k: Knowledge) -> Bool {
        guard case .session = phase else { return false }
        if k == .session { return true }
        let age = ContinuousClock.now - sessionAt
        guard stateXids.isEmpty || age > Remote.knowledgeWait.state else { return false }
        if k == .state { return true }
        guard let m = media else { return true }   // a TV reached by address has no AirPlay link
        guard m.isReady, let since = mediaReadyAt else { return linkFailed || age > Remote.knowledgeWait.link }
        if k == .link { return true }
        // MRP answers the queue request right after its handshake; nothing playing = no answer.
        return nowPlaying != nil || ContinuousClock.now - since > Remote.knowledgeWait.playing
    }

    /// Calls `done` once the TV has received everything sent so far, with `true`; or with
    /// `false` after `timeout` seconds or when the session ended first. A session that is
    /// about to be closed (tvctl without the app) waits for this: bytes handed to the
    /// network aren't known to arrive otherwise.
    ///
    /// How: a cheap request goes out behind everything else and the TV answers it (it reads
    /// the connection in order); MRP messages are acknowledged frame by frame
    /// (`MediaRemote.unacknowledged`). The answer also carries the media-control flags.
    public func flush(timeout: Double = 1, then done: @escaping @MainActor (Bool) -> Void) {
        guard case .session = phase else { return done(false) }
        var answered = false
        raw("FetchMediaControlStatus", [:]) { [weak self] reply, _ in
            answered = true
            self?.controlsAnswer(reply)
        }
        poll(for: timeout, until: { [weak self] in
            guard let self, case .session = self.phase else { return true }
            return answered && (self.media?.unacknowledged ?? 0) == 0
        }, then: { [weak self] _ in
            guard let self, case .session = self.phase else { return done(false) }
            done(answered)
        })
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

/// Calls `done(true)` as soon as `ready()` holds (checked now, then every 2 ms), or
/// `done(false)` once `seconds` have passed. For the few waits that have more than one
/// thing to wait for; nothing on a key press's path uses it.
@MainActor
func poll(for seconds: Double, until ready: @escaping @MainActor () -> Bool, then done: @escaping @MainActor (Bool) -> Void) {
    let start = ContinuousClock.now
    @MainActor func check() {
        if ready() { return done(true) }
        if ContinuousClock.now - start > .seconds(seconds) { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { MainActor.assumeIsolated { check() } }
    }
    check()
}
