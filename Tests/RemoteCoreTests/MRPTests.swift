import Foundation
import Testing
@testable import RemoteCore

private func msg(_ type: Int, ext: Int, _ body: (inout ProtoWriter) -> Void) -> [UInt8] {
    MediaRemote.message(type: type, ext: ext, body)
}

private func path(_ w: inout ProtoWriter, field: Int, client: String, player: String) {
    w.message(field) { p in
        p.message(2) { c in c.string(2, client) }
        p.message(3) { pl in pl.string(1, player) }
    }
}

/// ContentItem with metadata; options: (type, tag) for available (one group each) and current.
private func item(_ w: inout ProtoWriter, id: String, title: String, duration: Double, elapsed: Double, at: Double,
                  available: [(Int, String)] = [], current: [(Int, String)] = []) {
    w.message(2) { i in
        i.string(1, id)
        i.message(2) { md in
            md.string(1, title)
            md.double(14, duration)
            md.double(35, elapsed)
            md.double(74, at)
            md.float(39, 1)
        }
        for (t, tag) in available { i.message(5) { g in g.message(3) { o in o.int(1, t); o.string(2, tag) } } }
        for (t, tag) in current { i.message(6) { o in o.int(1, t); o.string(2, tag) } }
    }
}

@MainActor
private func session() -> MediaRemote {
    let creds = Credentials(clientID: Array("id".utf8), clientSeed: [UInt8](repeating: 1, count: 32), serverID: [1],
                            serverPublicKey: [UInt8](repeating: 2, count: 32))
    return MediaRemote(device: Device(name: "tv"), credentials: creds)
}

@Test @MainActor func mrpActivePlayerNowPlaying() {
    let m = session()
    var updates = 0
    m.onNowPlaying = { _ in updates += 1 }
    // Two apps report state; the TV says app B's player is the one playing.
    m.received(msg(4, ext: 9) { w in
        path(&w, field: 9, client: "com.a", player: "p1")
        w.int(6, 2)
        w.message(3) { q in q.int(1, 0); item(&q, id: "a1", title: "Paused Show", duration: 100, elapsed: 10, at: 0) }
    })
    m.received(msg(4, ext: 9) { w in
        path(&w, field: 9, client: "com.b", player: "main")
        w.int(6, 1)
        w.message(3) { q in
            q.int(1, 0)
            item(&q, id: "b1", title: "Movie", duration: 7200, elapsed: 600, at: 800_000_000,
                 available: [(0, "en"), (1, "en-US")], current: [(0, "en")])
        }
    })
    m.received(msg(46, ext: 50) { w in w.message(1) { c in c.string(2, "com.b") } })
    m.received(msg(47, ext: 51) { w in path(&w, field: 1, client: "com.b", player: "main") })
    let np = m.nowPlaying
    #expect(np?.title == "Movie")
    #expect(np?.duration == 7200)
    #expect(np?.elapsed == 600)
    #expect(np?.isPlaying == true)
    #expect(np?.hasCaptions == true && np?.captionsEnabled == false && np?.captionsFromMRP == true)
    #expect(abs((np?.position(at: Date(timeIntervalSinceReferenceDate: 800_000_010)) ?? 0) - 610) < 0.001)
    #expect(updates >= 1)

    // A metadata delta (pause + new elapsed) merges into the item.
    m.received(msg(56, ext: 60) { w in
        w.message(1) { i in i.string(1, "b1"); i.message(2) { md in md.double(35, 900); md.double(74, 800_000_100) } }
        path(&w, field: 2, client: "com.b", player: "main")
    })
    #expect(m.nowPlaying?.elapsed == 900)
    #expect(m.nowPlaying?.title == "Movie")   // untouched fields survive the merge

    // The app goes away: nothing is playing.
    m.received(msg(53, ext: 57) { w in w.message(1) { c in c.string(2, "com.b") } })
    #expect(m.nowPlaying == nil || m.nowPlaying?.title == "Paused Show")
}

@Test @MainActor func mrpLiveItemHasNoDuration() {
    let m = session()
    m.received(msg(4, ext: 9) { w in
        path(&w, field: 9, client: "com.tv", player: "MediaRemote-DefaultPlayer")
        w.int(6, 1)
        w.message(3) { q in
            q.int(1, 0)
            q.message(2) { i in i.string(1, "x"); i.message(2) { md in md.string(1, "Game"); md.bool(37, true); md.double(14, 1e9) } }
        }
    })
    #expect(m.nowPlaying?.title == "Game")
    #expect(m.nowPlaying?.duration == nil)
}

@Test func hidEventMatchesKnownGoodBytes() {
    // pyatv's verified example: left arrow down (page 1, usage 0x8B).
    let known = "438922cf0802000000000000000000000100000000000000020000002000000003000000010000000000000001008b00010000000000000001000000"
    let bytes = MediaRemote.hidEvent(page: 1, usage: 0x8B, down: true)
    #expect(bytes.count == 60)
    #expect(Hex.encode(bytes) == known)
    let mute = MediaRemote.hidEvent(page: 12, usage: 0xE2, down: false)
    #expect(Array(mute[43..<49]) == [0x00, 0x0C, 0x00, 0xE2, 0x00, 0x00])
}

@Test func protocolMessageEnvelope() throws {
    let m = try ProtoMessage(MediaRemote.message(type: 38, identifier: "X", ext: 42) { w in w.int(1, 2) })
    #expect(m.int(1) == 38)
    #expect(m.string(2) == "X")
    #expect(m.int(4) == 0)
    #expect(m.string(85)?.count == 36)
    #expect(m.message(42)?.int(1) == 2)
}
