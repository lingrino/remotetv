import Foundation
import os

/// MediaRemote (MRP) over the AirPlay tunnel: the system-wide now-playing state that every
/// app publishes (what Control Center shows), plus commands the Companion protocol lacks:
/// absolute seek and HID keys (mute).
///
/// Messages are `ProtocolMessage` protobufs: type (1), identifier (2), errorCode (4),
/// uniqueIdentifier (85), and the payload as an extension field whose number depends on
/// the type (`Ext`). Field numbers: pyatv's .proto files (see AGENTS.md).
///
/// Now-playing state is per player: clients (apps, by bundle id) own players; the TV says
/// which client and which of its players is active, and sends SetState (playback state,
/// queue of content items with metadata) and UpdateContentItem (metadata deltas) per player.
@MainActor
public final class MediaRemote {
    public let tunnel: AirPlayTunnel
    public private(set) var nowPlaying: NowPlaying?
    public private(set) var isReady = false
    public var onNowPlaying: ((NowPlaying?) -> Void)?
    public var onReady: ((Bool) -> Void)?
    /// Every decoded message type, for exploration (`tvctl mrp`).
    public var onTrace: ((String) -> Void)?
    /// Tunnel state changes (the tunnel's own callback belongs to this class).
    public var onTunnel: ((AirPlayTunnel.State) -> Void)?

    private let clientID: String
    private let name: String
    private static let log = Logger(subsystem: "com.lingrino.remotetv", category: "mrp")

    public init(device: Device, credentials: Credentials, name: String = "RemoteTV") {
        tunnel = AirPlayTunnel(device: device, credentials: credentials)
        clientID = String(decoding: credentials.clientID, as: UTF8.self)
        self.name = name
        tunnel.onState = { [weak self] s in self?.tunnelState(s) }
        tunnel.onMessage = { [weak self] m in self?.received(m) }
    }

    public var tunnelState: AirPlayTunnel.State { tunnel.state }

    public func start() { tunnel.connect() }

    public func stop() {
        tunnel.disconnect()
        reset()
    }

    private func reset() {
        clients.removeAll()
        activeClient = nil
        if isReady { isReady = false; onReady?(false) }
        if nowPlaying != nil { nowPlaying = nil; onNowPlaying?(nil) }
    }

    // MARK: - Message types and extension fields

    enum MessageType {
        static let sendCommand = 1, setState = 4, sendHIDEvent = 8, deviceInfo = 15, clientUpdatesConfig = 16
        static let volumeControlAvailability = 17, getKeyboardSession = 24, playbackQueueRequest = 32
        static let setConnectionState = 38, generic = 42, setNowPlayingClient = 46, setNowPlayingPlayer = 47
        static let volumeDidChange = 52, removeClient = 53, removePlayer = 54, updateClient = 55, updateContentItem = 56
    }

    enum Ext {
        static let sendCommand = 6, sendCommandResult = 7, setState = 9, sendHIDEvent = 13, deviceInfo = 20
        static let clientUpdatesConfig = 21, volumeControlAvailability = 22, setConnectionState = 42
        static let setNowPlayingClient = 50, setNowPlayingPlayer = 51, volumeDidChange = 56, removeClient = 57
        static let removePlayer = 58, updateClient = 59, updateContentItem = 60
    }

    /// A serialized ProtocolMessage. `ext` holds the payload when given.
    nonisolated static func message(type: Int, identifier: String? = nil, ext: Int? = nil,
                        _ body: (inout ProtoWriter) -> Void = { _ in }) -> [UInt8] {
        var w = ProtoWriter()
        w.int(1, type)
        if let identifier { w.string(2, identifier) }
        w.int(4, 0)
        w.string(85, UUID().uuidString)
        if let ext { w.message(ext, body) }
        return w.bytes
    }

    // MARK: - Handshake

    private var handshakeID = ""

    private func tunnelState(_ s: AirPlayTunnel.State) {
        onTunnel?(s)
        switch s {
        case .ready:
            handshakeID = UUID().uuidString
            // DEVICE_INFORMATION must come first; the rest follows its reply.
            tunnel.send(MediaRemote.message(type: MessageType.deviceInfo, identifier: handshakeID, ext: Ext.deviceInfo) { w in
                w.string(1, self.clientID)            // uniqueIdentifier
                w.string(2, self.name)                // name
                w.string(3, "iPhone")                 // localizedModelName
                w.string(4, "18G82")                  // systemBuildVersion
                w.string(5, "com.apple.TVRemote")     // applicationBundleIdentifier
                w.string(6, "344.28")                 // applicationBundleVersion
                w.int(7, 1)                           // protocolVersion
                w.int(8, 108)                         // lastSupportedMessageType
                w.bool(9, true)                       // supportsSystemPairing
                w.bool(10, true)                      // allowsPairing
                w.string(12, "com.apple.TVMusic")     // systemMediaApplication
                w.bool(13, true)                      // supportsACL
                w.bool(14, true)                      // supportsSharedQueue
                w.bool(15, true)                      // supportsExtendedMotion
                w.int(17, 2)                          // sharedQueueVersion
                w.int(21, 1)                          // deviceClass: iPhone
                w.int(22, 1)                          // logicalDeviceCount
            })
        case .failed, .idle:
            reset()
        case .connecting:
            break
        }
    }

    private func handshakeReply() {
        tunnel.send(MediaRemote.message(type: MessageType.setConnectionState, ext: Ext.setConnectionState) { w in
            w.int(1, 2)   // Connected
        })
        tunnel.send(MediaRemote.message(type: MessageType.clientUpdatesConfig, identifier: UUID().uuidString,
                                        ext: Ext.clientUpdatesConfig) { w in
            w.bool(1, true)    // artworkUpdates
            w.bool(2, true)    // nowPlayingUpdates
            w.bool(3, true)    // volumeUpdates
            w.bool(4, true)    // keyboardUpdates
            w.bool(5, true)    // outputDeviceUpdates
        })
        tunnel.send(MediaRemote.message(type: MessageType.getKeyboardSession, identifier: UUID().uuidString))
        isReady = true
        onReady?(true)
        refresh()
    }

    /// Asks for the current item (the TV answers with a SetState carrying the queue).
    public func refresh() {
        guard isReady else { return }
        tunnel.send(MediaRemote.message(type: MessageType.playbackQueueRequest, identifier: UUID().uuidString,
                                        ext: 37) { w in
            w.int(1, 0)          // location
            w.int(2, 1)          // length
            w.bool(3, true)      // includeMetadata
            w.bool(9, true)      // includeLanguageOptions
            w.bool(13, true)     // returnContentItemAssetsInUserCompletion
        })
    }

    // MARK: - Commands

    /// Mute toggle: the HID consumer-page Mute key (page 12, usage 0xE2), down and up,
    /// then an empty generic message to flush (as the iOS remote's key path does).
    public func toggleMute() {
        hidKey(page: 12, usage: 0xE2)
    }

    func hidKey(page: UInt16, usage: UInt16) {
        guard isReady else { return }
        for down in [true, false] {
            tunnel.send(MediaRemote.message(type: MessageType.sendHIDEvent, ext: Ext.sendHIDEvent) { w in
                w.data(1, MediaRemote.hidEvent(page: page, usage: usage, down: down))
            })
        }
        tunnel.send(MediaRemote.message(type: MessageType.generic, identifier: UUID().uuidString))
    }

    /// The 60-byte IOHIDEvent blob: a fixed template with the usage page (bytes 43–44),
    /// usage (45–46) and down flag (47–48), big-endian.
    nonisolated static func hidEvent(page: UInt16, usage: UInt16, down: Bool) -> [UInt8] {
        var b: [UInt8] = [
            0x43, 0x89, 0x22, 0xCF, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00,
            0, 0, 0, 0, 0, 0,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        ]
        b[43] = UInt8(page >> 8); b[44] = UInt8(page & 0xFF)
        b[45] = UInt8(usage >> 8); b[46] = UInt8(usage & 0xFF)
        b[48] = down ? 1 : 0
        return b
    }

    /// Absolute seek on the active player (SeekToPlaybackPosition).
    public func seek(to seconds: Double) {
        guard isReady else { return }
        tunnel.send(MediaRemote.message(type: MessageType.sendCommand, identifier: UUID().uuidString, ext: Ext.sendCommand) { w in
            w.int(1, 45)
            w.message(2) { o in o.double(9, max(0, seconds)) }
        })
        // Show it right away; the TV's SetState follows.
        if var np = nowPlaying {
            np.elapsed = max(0, seconds)
            np.timestamp = Date().timeIntervalSinceReferenceDate
            nowPlaying = np
            onNowPlaying?(np)
        }
    }

    /// Whether the active player accepts a command (e.g. 45 seek).
    public func supports(_ command: Int) -> Bool {
        activePlayer?.commands.contains { $0.int(1) == command && ($0.bool(2) ?? true) } ?? false
    }

    // MARK: - State

    private struct Player {
        var state = 0
        var commands: [ProtoMessage] = []
        var items: [(id: String?, item: [UInt8])] = []
        var location = 0
    }

    private struct Client {
        var players: [String: Player] = [:]
        var activePlayer: String?
    }

    private var clients: [String: Client] = [:]
    private var activeClient: String?
    private static let defaultPlayer = "MediaRemote-DefaultPlayer"

    private var activePlayer: Player? {
        guard let c = activeClient.flatMap({ clients[$0] }) else { return nil }
        if let id = c.activePlayer, let p = c.players[id] { return p }
        return c.players[MediaRemote.defaultPlayer] ?? c.players.values.first
    }

    /// (bundle id, player id) from a PlayerPath.
    private static func path(_ p: ProtoMessage?) -> (String, String) {
        (p?.message(2)?.string(2) ?? "", p?.message(3)?.string(1) ?? defaultPlayer)
    }

    func received(_ bytes: [UInt8]) {
        guard let m = try? ProtoMessage(bytes), let type = m.int(1) else { return }
        onTrace?("type \(type) \(bytes.count) B")
        switch type {
        case MessageType.deviceInfo:
            if !isReady { handshakeReply() }
        case MessageType.setState:
            guard let s = m.message(Ext.setState) else { return }
            let (client, player) = MediaRemote.path(s.message(9))
            var p = clients[client, default: Client()].players[player, default: Player()]
            if let st = s.int(6) { p.state = st }
            if let sc = s.message(2) { p.commands = sc.messages(1) }
            if let q = s.message(3) {
                if let onTrace {
                    for item in q.messages(2) where item.has(3) {
                        onTrace("  artwork \(item.bytes(3)?.count ?? 0) B \(item.int(13) ?? 0)x\(item.int(14) ?? 0) \(item.message(2)?.string(31) ?? "")")
                    }
                    for item in q.messages(2) {
                        let legible = item.messages(5).flatMap { $0.messages(3) }.filter { $0.int(1) == 1 }.count
                        onTrace("  setState client=\(client) player=\(player) state=\(s.int(6).map(String.init) ?? "-") item=\(item.string(1)?.prefix(40) ?? "?") title=\(item.message(2)?.string(1) ?? "-") legible=\(legible) current=\(item.messages(6).map { $0.int(1) ?? -1 })")
                    }
                }
                p.location = q.int(1) ?? 0
                p.items = q.messages(2).map { ($0.string(1), $0.fields.isEmpty ? [] : MediaRemote.reencode($0)) }
            }
            clients[client, default: Client()].players[player] = p
            if activeClient == nil { activeClient = client }
            publish()
        case MessageType.updateContentItem:
            guard let u = m.message(Ext.updateContentItem) else { return }
            let (client, player) = MediaRemote.path(u.message(2))
            guard var p = clients[client]?.players[player] else { return }
            for item in u.messages(1) {
                guard let id = item.string(1), let i = p.items.firstIndex(where: { $0.id == id }) else { continue }
                // Protobuf merge = concatenation: later fields win.
                var merged = p.items[i].item + MediaRemote.reencode(item)
                if merged.count > 1 << 16 { merged = MediaRemote.reencode(item) }
                p.items[i].item = merged
            }
            clients[client]?.players[player] = p
            publish()
        case MessageType.setNowPlayingClient:
            activeClient = m.message(Ext.setNowPlayingClient)?.message(1)?.string(2)
            onTrace?("  nowPlayingClient=\(activeClient ?? "nil")")
            publish()
        case MessageType.setNowPlayingPlayer:
            let (client, player) = MediaRemote.path(m.message(Ext.setNowPlayingPlayer)?.message(1))
            clients[client, default: Client()].activePlayer = player
            onTrace?("  nowPlayingPlayer client=\(client) player=\(player)")
            publish()
        case MessageType.removeClient:
            if let b = m.message(Ext.removeClient)?.message(1)?.string(2) {
                clients[b] = nil
                if activeClient == b { activeClient = nil }
                publish()
            }
        case MessageType.removePlayer:
            let (client, player) = MediaRemote.path(m.message(Ext.removePlayer)?.message(1))
            clients[client]?.players[player] = nil
            if clients[client]?.activePlayer == player { clients[client]?.activePlayer = nil }
            publish()
        default:
            break
        }
    }

    /// The serialized form of a decoded message (its fields, in order).
    private static func reencode(_ m: ProtoMessage) -> [UInt8] {
        var w = ProtoWriter()
        for (f, v) in m.fields {
            switch v {
            case .varint(let x): w.varint(f, x)
            case .fixed64(let x): w.double(f, Double(bitPattern: x))
            case .fixed32(let x): w.float(f, Float(bitPattern: x))
            case .bytes(let b): w.data(f, Array(b))
            }
        }
        return w.bytes
    }

    private func publish() {
        let np = activePlayer.flatMap(MediaRemote.nowPlaying(from:))
        guard np != nowPlaying else { return }
        nowPlaying = np
        onNowPlaying?(np)
    }

    /// ContentItemMetadata fields: title 1, subtitle 2, seasonNumber 10, episodeNumber 11,
    /// duration 14, isAlwaysLive 37, elapsedTime 35, playbackRate 39, seriesName 63,
    /// elapsedTimeTimestamp 74 (seconds since 2001). ContentItem: identifier 1,
    /// metadata 2, availableLanguageOptions 5, currentLanguageOptions 6.
    private static func nowPlaying(from p: Player) -> NowPlaying? {
        guard p.location < p.items.count, let item = try? ProtoMessage(p.items[p.location].item),
              let md = item.message(2) else { return nil }
        let title = md.string(1)
        let duration = md.double(14).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        guard title != nil || duration != nil else { return nil }
        let playing = p.state == 1
        let rate = md.float(39).map(Double.init) ?? (playing ? 1 : 0)
        var np = NowPlaying(title: title, duration: md.bool(37) == true ? nil : duration,
                            elapsed: md.double(35) ?? 0,
                            timestamp: md.double(74) ?? Date().timeIntervalSinceReferenceDate,
                            rate: playing ? rate : 0, state: p.state)
        np.subtitle = md.string(63).flatMap { $0 == title ? nil : $0 } ?? md.string(2)
        np.bundleID = nil
        // Subtitles: legible (type 1) options available / selected.
        let legibleAvailable = item.messages(5).contains { g in g.messages(3).contains { $0.int(1) == 1 } }
        np.hasCaptions = legibleAvailable
        np.captionsEnabled = item.messages(6).contains { $0.int(1) == 1 }
        np.captionsFromMRP = legibleAvailable || md.bool(22) != nil
        return np
    }
}
