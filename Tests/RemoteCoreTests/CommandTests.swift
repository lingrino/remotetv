import Foundation
import Network
import Testing
@testable import RemoteCore

/// `TVCommand` the way tvctl uses it without the app (a `Remote` that isn't connected yet:
/// connect, wait for what the command reads, run, flush, goodbye), against the loopback
/// FakeTV. Part of SessionTests so that everything that shortens Remote's timing constants
/// runs one test at a time.
extension SessionTests {
    private func fresh(_ tv: FakeTV) async throws -> Remote {
        try await tv.start()
        return Remote(device: tv.device, credentials: tv.credentials)
    }

    @Test func aCommandConnectsRunsAndIsDeliveredBeforeLeaving() async throws {
        let tv = FakeTV()
        let r = try await fresh(tv)
        var reply: (String, Int32)?
        var delivered: Bool?
        var pressesAtFlush = 0
        var left = false
        TVCommand.run(["press", "select", "down"], on: r) { text, code in
            reply = (text, code)
            r.flush { ok in
                delivered = ok
                pressesAtFlush = tv.presses.count   // the TV answered: it has everything before
                r.goodbye { left = true }
            }
        }
        #expect(await eventually { left })
        #expect(reply?.0 == "" && reply?.1 == 0)
        #expect(delivered == true)
        #expect(pressesAtFlush == 4)
        #expect(tv.presses.map(\.0) == [6, 6, 2, 2])
        #expect(await eventually { tv.received.contains { $0["_i"]?.string == "_sessionStop" } })
        #expect(r.status == .idle)
        tv.stop()
    }

    @Test func aTypoNeverTouchesTheTV() async throws {
        let tv = FakeTV()
        let r = try await fresh(tv)
        var replies: [(String, Int32)] = []
        TVCommand.run(["press", "sideways"], on: r) { replies.append(($0, $1)) }
        TVCommand.run(["frobnicate"], on: r) { replies.append(($0, $1)) }
        TVCommand.run(["skip"], on: r) { replies.append(($0, $1)) }
        TVCommand.run(["mute", "please"], on: r) { replies.append(($0, $1)) }
        TVCommand.run(["--tv"], on: r) { replies.append(($0, $1)) }
        #expect(replies.map(\.1) == [2, 2, 2, 2, 2])   // answered on the spot: not understood
        #expect(replies.first?.0.contains("sideways") == true)
        #expect(replies.first?.0.contains("usage: tvctl press") == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.status == .idle)
        #expect(tv.received.isEmpty)
        tv.stop()
    }

    @Test func aCommandOnALiveSessionRunsAtOnce() async throws {
        let tv = FakeTV()
        let r = try await fresh(tv)
        r.connect()
        #expect(await eventually { r.knows(.playing) })
        var reply: (String, Int32)?
        TVCommand.run(["np"], on: r) { reply = ($0, $1) }
        #expect(reply?.0 == "nothing is playing" && reply?.1 == 0)   // no waiting: already known
        r.disconnect()
        tv.stop()
    }

    @Test func aFailedConnectIsRetried() async throws {
        let tv = FakeTV()
        tv.verifyError = 6   // busy
        let r = try await fresh(tv)
        var reply: (String, Int32)?
        TVCommand.run(["press", "up"], on: r) { reply = ($0, $1) }
        #expect(await eventually { r.status.isFailure })
        #expect(reply == nil)
        tv.verifyError = nil
        #expect(await eventually { reply != nil })
        #expect(reply?.1 == 0)
        #expect(await eventually { tv.presses.count == 2 })
        r.disconnect()
        tv.stop()
    }

    @Test func aForgottenPairingFailsWithoutWaiting() async throws {
        let tv = FakeTV()
        tv.verifyError = 2
        let r = try await fresh(tv)
        var reply: (String, Int32)?
        let start = ContinuousClock.now
        TVCommand.run(["press", "up"], on: r, within: 30) { reply = ($0, $1) }
        #expect(await eventually { reply != nil })
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(reply?.1 == 1)
        #expect(reply?.0.contains("pair again") == true)
        tv.stop()
    }

    @Test func anUnreachableTVFailsWhenTheTimeIsUp() async throws {
        // Nothing listens on port 1: refused, retried, then given up on.
        let nowhere = Device(name: "nowhere", model: "AppleTV", endpoint: .hostPort(host: "127.0.0.1", port: 1))
        let r = Remote(device: nowhere, credentials: FakeTV().credentials)
        var reply: (String, Int32)?
        let start = ContinuousClock.now
        TVCommand.run(["press", "up"], on: r, within: 0.7) { reply = ($0, $1) }
        #expect(await eventually { reply != nil })
        #expect(ContinuousClock.now - start >= .milliseconds(700))
        #expect(reply?.1 == 1)
        #expect(reply?.0.hasPrefix("nowhere: ") == true)
        r.disconnect()
    }

    @Test func aToggleWaitsToLearnWhichWay() async throws {
        let tv = FakeTV()
        tv.answers["FetchAttentionState"] = false   // answered by hand below
        let r = try await fresh(tv)
        var reply: (String, Int32)?
        TVCommand.run(["power", "toggle"], on: r) { reply = ($0, $1) }
        let asked = { tv.received.first { $0["_i"]?.string == "FetchAttentionState" } }
        #expect(await eventually { asked() != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(reply == nil)   // connected, but whether the TV is asleep isn't known yet
        let x = try #require(asked()?["_x"]?.int)
        tv.send(.dict(["_t": .int(3), "_x": .int(x), "_c": .dict(["state": .int(1)])]))   // asleep
        #expect(await eventually { reply != nil })
        #expect(reply?.1 == 0)
        #expect(await eventually { tv.presses.count == 1 })
        #expect(tv.presses.first?.0 == Int64(Button.wake.rawValue))   // wake, not sleep
        r.disconnect()
        tv.stop()
    }

    @Test func knowledgeStopsWaitingForAnAnswerThatNeverComes() async throws {
        let saved = Remote.knowledgeWait
        Remote.knowledgeWait.state = .milliseconds(300)
        defer { Remote.knowledgeWait = saved }
        let tv = FakeTV()
        tv.answers["_tiStart"] = false
        let r = try await fresh(tv)
        r.connect()
        #expect(await eventually { r.status == .connected })
        #expect(r.knows(.session))
        #expect(!r.knows(.state))
        #expect(await eventually(2) { r.knows(.state) })
        #expect(r.knows(.playing))   // a TV reached by address has no AirPlay link to wait for
        r.disconnect()
        #expect(!r.knows(.session))
        tv.stop()
    }

    @Test func flushSaysWhenTheTVDidNotAnswer() async throws {
        let tv = FakeTV()
        let r = try await fresh(tv)
        var result: Bool?
        r.flush { result = $0 }
        #expect(result == false)   // no session: nothing was delivered
        r.connect()
        #expect(await eventually { r.status == .connected })
        tv.answers["FetchMediaControlStatus"] = false
        result = nil
        r.flush(timeout: 0.2) { result = $0 }
        #expect(await eventually { result != nil })
        #expect(result == false)
        r.disconnect()
        tv.stop()
    }

    @Test func statusOfANewSessionIsComplete() async throws {
        let tv = FakeTV()
        let r = try await fresh(tv)
        var reply: (String, Int32)?
        TVCommand.run(["status"], on: r) { reply = ($0, $1) }
        #expect(await eventually { reply != nil })
        let lines = reply?.0.split(separator: "\n").map(String.init) ?? []
        #expect(reply?.1 == 0)
        #expect(lines.first == "\(r.device.name): connected")
        #expect(lines.count == 6)
        // The control flags were asked for (they are an event a new session hasn't had).
        #expect(tv.received.contains { $0["_i"]?.string == "FetchMediaControlStatus" })
        r.disconnect()
        tv.stop()
    }

    // MARK: The commands themselves

    /// A connected session and what a command on it replied.
    private func session(_ tv: FakeTV) async throws -> Remote {
        let r = try await fresh(tv)
        r.connect()
        #expect(await eventually { r.knows(.playing) })
        return r
    }

    private func run(_ args: String..., on r: Remote) async -> (text: String, code: Int32) {
        var reply: (String, Int32)?
        TVCommand.run(args, on: r) { reply = ($0, $1) }
        _ = await eventually(8) { reply != nil }
        return reply ?? ("no reply", -1)
    }

    private func playing(_ r: Remote, rate: Double) {
        r.companionPlaying = NowPlaying(title: "Movie", duration: 3600, elapsed: 60,
                                        timestamp: Date().timeIntervalSinceReferenceDate, rate: rate, state: rate == 0 ? 2 : 1)
        r.publishNowPlaying()
    }

    @Test func playAndPauseOnlyActWhenNeeded() async throws {
        let tv = FakeTV()
        let r = try await session(tv)
        // Nothing playing: nothing to pause.
        #expect(await run("pause", on: r) == ("nothing is playing", 0))
        #expect(tv.presses.isEmpty)
        playing(r, rate: 1)
        #expect(await run("play", on: r) == ("already playing", 0))
        #expect(tv.presses.isEmpty)
        #expect(await run("--json", "pause", on: r) == ("{\"ok\":true,\"changed\":true}", 0))
        #expect(await eventually { tv.presses.count == 2 })
        #expect(tv.presses.first?.0 == Int64(Button.playPause.rawValue))
        playing(r, rate: 0)
        #expect(await run("--json", "pause", on: r) == ("{\"ok\":true,\"changed\":false}", 0))
        #expect(await run("play", on: r) == ("", 0))
        #expect(await eventually { tv.presses.count == 4 })
        r.disconnect()
        tv.stop()
    }

    @Test func nowPlayingAsTextAndJSON() async throws {
        let tv = FakeTV()
        let r = try await session(tv)
        #expect(await run("--json", "playing", on: r) == ("{\"ok\":true,\"now_playing\":null}", 0))
        playing(r, rate: 0)
        #expect(await run("playing", on: r) == ("Movie  1:00 / 1:00:00  paused", 0))
        let json = await run("playing", "--json", on: r)   // the option works after the command too
        #expect(json.text == "{\"ok\":true,\"now_playing\":{\"title\":\"Movie\",\"subtitle\":null,\"app\":null,"
                + "\"state\":\"paused\",\"position\":60,\"duration\":3600,\"captions\":null}}")
        r.disconnect()
        tv.stop()
    }

    @Test func failuresAreJSONToo() async throws {
        let tv = FakeTV()
        let r = try await session(tv)
        #expect(await run("--json", "seek", "1:00", on: r) == ("{\"ok\":false,\"error\":\"nothing is playing\"}", 1))
        let typo = await run("--json", "seek", on: r)
        #expect(typo.code == 2)
        #expect(typo.text.hasPrefix("{\"ok\":false,\"error\":\"seek takes a position"))
        r.disconnect()
        tv.stop()
    }

    @Test func pressPausesBetweenButtons() async throws {
        let tv = FakeTV()
        let r = try await session(tv)
        var done = false
        TVCommand.run(["press", "up", "0.3", "down"], on: r) { _, _ in done = true }
        #expect(await eventually { tv.presses.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(tv.presses.count == 2 && !done)   // waiting before "down"
        #expect(await eventually { tv.presses.count == 4 && done })
        #expect(tv.presses.map(\.0) == [1, 1, 2, 2])
        #expect(await run("press", "up", "9", "6", "down", on: r).code == 2)   // too long a wait
        #expect(await run("volume", "up", "3", on: r) == ("", 0))
        #expect(await eventually { tv.presses.count == 10 })
        r.disconnect()
        tv.stop()
    }

    @Test func launchFindsTheAppByName() async throws {
        let tv = FakeTV()
        tv.contents["FetchLaunchableApplicationsEvent"] = .dict([
            "com.netflix.Netflix": .string("Netflix"), "com.apple.TVMusic": .string("Music"),
            "com.apple.TVWatchList": .string("TV"), "com.apple.TVShows": .string("TV Shows")])
        let r = try await session(tv)
        let launched = { tv.received.filter { $0["_i"]?.string == "_launchApp" }.compactMap { $0["_c"]?["_bundleID"]?.string } }
        #expect(await run("launch", "netfl", on: r) == ("", 0))
        #expect(await eventually { launched() == ["com.netflix.Netflix"] })
        #expect(await run("--json", "launch", "tv", on: r)
                == ("{\"ok\":true,\"launched\":{\"name\":\"TV\",\"bundle_id\":\"com.apple.TVWatchList\"}}", 0))   // the exact name wins
        #expect(await run("launch", "com.apple.tvmusic", on: r).code == 0)
        #expect(await eventually { launched().count == 3 })
        #expect(await run("launch", "m", on: r).code == 0)   // only Music starts with it
        let none = await run("launch", "hulu", on: r)
        #expect(none.code == 1 && none.text.contains("no app called \"hulu\""))
        #expect(launched().count == 4)
        let apps = await run("apps", on: r)
        #expect(apps.text.split(separator: "\n").first == "Music     com.apple.TVMusic")
        r.disconnect()
        tv.stop()
    }

    @Test func powerShowsOrSets() async throws {
        let tv = FakeTV()
        tv.contents["FetchAttentionState"] = .dict(["state": .int(1)])
        let r = try await session(tv)
        #expect(await run("power", on: r) == ("asleep", 0))
        #expect(tv.presses.isEmpty)
        #expect(await run("wake", on: r) == ("", 0))   // = power on
        #expect(await eventually { tv.presses.count == 1 })
        #expect(tv.presses.first?.0 == Int64(Button.wake.rawValue))
        #expect(await run("--json", "power", on: r) == ("{\"ok\":true,\"power\":\"awake\"}", 0))
        #expect(await run("power", "maybe", on: r).code == 2)
        r.disconnect()
        tv.stop()
    }

    @Test func textNeedsAFocusedField() async throws {
        let tv = FakeTV()
        let r = try await session(tv)
        #expect(await run("type", "hello", on: r) == ("no text field is focused on the TV", 1))
        #expect(await run("text", on: r).code == 1)
        #expect(await run("type", on: r).code == 2)
        r.disconnect()
        tv.stop()
    }
}
