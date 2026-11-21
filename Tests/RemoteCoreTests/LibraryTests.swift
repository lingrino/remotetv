import Foundation
import Testing
@testable import RemoteCore

/// A TVRCUpNextInfo-shaped archive (same classes and keys as the TV sends).
private func upNextArchive(title: String, season: Plist?, episode: Plist?, url: String) -> [UInt8] {
    var b = ArchiveBuilder()
    let rel = b.add(.string(url))
    let nsurl = b.object("NSURL", [("NS.base", .uid(0)), ("NS.relative", .uid(rel))])
    var mi: [(String, Plist)] = [("title", .uid(b.add(.string(title)))),
                                 ("identifier", .uid(b.add(.string("umc.cmc.x")))),
                                 ("imageURLTemplate", .uid(b.add(.string("https://img.example/{w}x{h}.{f}"))))]
    if let season { mi.append(("seasonNumber", season)) }
    if let episode { mi.append(("episodeNumber", episode)) }
    let media = b.object("TVRCMediaInfo", mi)
    let root = b.object("TVRCUpNextInfo", [("actionURL", .uid(nsurl)), ("mediaInfo", .uid(media)),
                                           ("service", .uid(b.add(.string("Hulu")))),
                                           ("reason", .uid(b.add(.string("New Episode"))))])
    return b.archive(top: [("root", root)])
}

@Test func upNextItemParsing() throws {
    let a = try #require(UpNextItem(archive: upNextArchive(title: "A Show", season: .int(1), episode: .real(5),
                                                           url: "streamer://videos/abc?play=true")))
    #expect(a.title == "A Show")
    #expect(a.subtitle == "S1 · E5")
    #expect(a.service == "Hulu" && a.reason == "New Episode")
    #expect(a.actionURL == "streamer://videos/abc?play=true")
    #expect(a.imageURL(width: 320, height: 180)?.absoluteString == "https://img.example/320x180.jpg")
    let movie = try #require(UpNextItem(archive: upNextArchive(title: "A Movie", season: nil, episode: nil, url: "x://y")))
    #expect(movie.subtitle == nil)
}

@Test @MainActor func mrpArtworkAskedOncePerItem() {
    let creds = Credentials(clientID: Array("id".utf8), clientSeed: [UInt8](repeating: 1, count: 32), serverID: [1],
                            serverPublicKey: [UInt8](repeating: 2, count: 32))
    let m = MediaRemote(device: Device(name: "tv"), credentials: creds)
    func state(art: [UInt8]?) -> [UInt8] {
        MediaRemote.message(type: 4, ext: 9) { w in
            w.message(9) { p in p.message(2) { c in c.string(2, "com.app") }; p.message(3) { pl in pl.string(1, "main") } }
            w.int(6, 1)
            w.message(3) { q in
                q.int(1, 0)
                q.message(2) { i in
                    i.string(1, "item-1")
                    i.message(2) { md in md.string(1, "Show"); md.double(14, 100) }
                    if let art { i.data(3, art) }
                }
            }
        }
    }
    m.wantsArtwork = true
    m.received(state(art: nil))
    #expect(m.nowPlaying?.itemID == "item-1")
    #expect(m.nowPlaying?.artwork == nil)
    m.received(state(art: [0xFF, 0xD8, 0xFF]))          // the reply to the artwork request
    #expect(m.nowPlaying?.artwork == [0xFF, 0xD8, 0xFF])
    m.received(state(art: nil))                         // later updates keep it
    #expect(m.nowPlaying?.artwork == [0xFF, 0xD8, 0xFF])
    #expect(m.nowPlaying?.bundleID == "com.app")
}
