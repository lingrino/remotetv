import Foundation
import Testing
@testable import RemoteCore

/// `Remote` against the loopback FakeTV: the state machine, liveness, and trust boundary.
/// Serialized: some tests shorten Remote's timing constants.
@Suite(.serialized) @MainActor
struct SessionTests {
    private func connected(_ tv: FakeTV) async throws -> Remote {
        try await tv.start()
        let r = Remote(device: tv.device, credentials: tv.credentials)
        r.connect()
        #expect(await eventually { r.status == .connected })
        return r
    }

    @Test func connectsAndPresses() async throws {
        let tv = FakeTV()
        let r = try await connected(tv)
        r.press(.select)
        #expect(await eventually { tv.presses.count == 2 })
        #expect(tv.presses.map(\.0) == [6, 6] && tv.presses.map(\.1) == [true, false])
        r.disconnect()
        tv.stop()
    }

    @Test func messagesBeforeEncryptionAreIgnored() async throws {
        let tv = FakeTV()
        // A plaintext event sent before pair-verify must not reach the app.
        var events = 0
        try await tv.start()
        let r = Remote(device: tv.device, credentials: tv.credentials)
        r.onTextSession = { _ in events += 1 }
        r.onControls = { _ in events += 1 }
        tv.preAuthFrame = (.unencryptedOPACK, OPACK.encode(.dict(["_t": .int(1), "_i": .string("_iMC"),
                                                                  "_c": .dict(["_mcF": .int(1)])])))
        r.connect()
        #expect(await eventually { r.status == .connected })
        try await Task.sleep(for: .milliseconds(100))
        #expect(events == 0)
        #expect(!r.controlsKnown)
        // The same event inside the session is accepted.
        tv.send(.dict(["_t": .int(1), "_i": .string("_iMC"), "_c": .dict(["_mcF": .int(1)])]))
        #expect(await eventually { r.controlsKnown })
        r.disconnect()
        tv.stop()
    }

    @Test func pendingRequestsCompleteWhenTheConnectionDrops() async throws {
        let tv = FakeTV()
        tv.answers["FetchUpNextInfoEvent"] = false
        let r = try await connected(tv)
        var result: [UpNextItem]?? = .none
        r.fetchUpNext { result = .some($0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(result == nil)
        tv.drop()
        #expect(await eventually(2) { result != nil })
        #expect(result == .some(nil))   // completed, with "couldn't say"
        r.disconnect()
        tv.stop()
    }

    @Test func pendingRequestsTimeOut() async throws {
        let saved = Remote.rawTimeout
        Remote.rawTimeout = 0.3
        defer { Remote.rawTimeout = saved }
        let tv = FakeTV()
        tv.answers["FetchUpNextInfoEvent"] = false
        let r = try await connected(tv)
        var done = false
        r.fetchUpNext { _ in done = true }
        #expect(await eventually(2) { done })
        r.disconnect()
        tv.stop()
    }

    @Test func aTVThatStopsAnsweringIsDropped() async throws {
        let saved = Remote.deafAfter
        Remote.deafAfter = .milliseconds(300)
        defer { Remote.deafAfter = saved }
        let tv = FakeTV()
        let r = try await connected(tv)
        tv.answers["_hidC"] = false
        r.press(.down)
        #expect(await eventually(3) { r.status.isFailure })
        r.disconnect()
        tv.stop()
    }

    @Test func anUnreadableMessageDoesNotEndTheSession() async throws {
        let tv = FakeTV()
        let r = try await connected(tv)
        tv.sendRaw([0xFF, 0xFE, 0x00])          // not OPACK
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.status == .connected)
        r.press(.menu)
        #expect(await eventually { tv.presses.count == 2 })
        r.disconnect()
        tv.stop()
    }

    @Test func aForgottenPairingIsReportedNotRetried() async throws {
        let tv = FakeTV()
        tv.verifyError = 2
        try await tv.start()
        let r = Remote(device: tv.device, credentials: tv.credentials)
        r.connect()
        #expect(await eventually { r.status == .unpaired })
        tv.stop()
    }

    @Test func otherPairVerifyErrorsAreRetryable() async throws {
        let tv = FakeTV()
        tv.verifyError = 6   // busy
        try await tv.start()
        let r = Remote(device: tv.device, credentials: tv.credentials)
        r.connect()
        #expect(await eventually { r.status.isFailure })
        tv.stop()
    }

    @Test func pressesQueuedTooLongAreNotReplayed() async throws {
        let saved = Remote.queueMaxAge
        Remote.queueMaxAge = .milliseconds(150)
        defer { Remote.queueMaxAge = saved }
        let tv = FakeTV()
        tv.verifyDelay = 0.4            // a slow connect
        try await tv.start()
        let r = Remote(device: tv.device, credentials: tv.credentials)
        r.press(.select)                // queued; starts the connect
        #expect(await eventually { r.status == .connected })
        try await Task.sleep(for: .milliseconds(100))
        #expect(tv.presses.isEmpty)
        r.press(.up)                    // a fresh press goes through
        #expect(await eventually { tv.presses.count == 2 })
        r.disconnect()
        tv.stop()
    }
}
