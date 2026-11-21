import Foundation

/// What the Apple TV is playing, from the `NowPlayingInfo` event: an NSKeyedArchiver
/// archive of `TVRCNowPlayingInfo` (playbackRate, playbackState, captionsEnabled,
/// hasValidCaptionOptions, imageData, metadata: TVRCNowPlayingMetadata with title,
/// episodeTitle, duration, timeOffset, timestamp, bundleID, …).
///
/// Position is extrapolated: `elapsed` was the position at `timestamp` (the TV's clock,
/// seconds since 2001), advancing at `rate`. The TV sends a new snapshot when playback
/// state changes, not every second.
public struct NowPlaying: Sendable, Equatable {
    public var title: String?
    public var subtitle: String?
    public var duration: Double?
    public var elapsed: Double
    public var timestamp: Double
    public var rate: Double
    /// 1 playing, 2 paused (others: stopped/interrupted/seeking).
    public var state: Int
    public var captionsEnabled: Bool
    public var hasCaptions: Bool
    public var bundleID: String?
    public var artwork: [UInt8]?

    public var isPlaying: Bool { state == 1 && rate != 0 }

    /// Seconds into the item at `now`, clamped to the duration.
    public func position(at now: Date = Date()) -> Double {
        var p = elapsed
        if isPlaying { p += (now.timeIntervalSinceReferenceDate - timestamp) * rate }
        p = max(0, p)
        if let duration, duration > 0 { p = min(p, duration) }
        return p
    }

    /// Parses `NowPlayingInfoKey`; nil if the archive has no item.
    public init?(archive bytes: [UInt8]) {
        guard let a = try? KeyedArchive(bytes), let root = a.root else { return nil }
        let md = a.field(root, "metadata")
        title = a.field(md, "title")?.string
        subtitle = a.field(md, "episodeTitle")?.string
        duration = a.field(md, "duration")?.double
        elapsed = a.field(md, "timeOffset")?.double ?? 0
        timestamp = a.field(md, "timestamp")?.double ?? Date().timeIntervalSinceReferenceDate
        rate = a.field(root, "playbackRate")?.double ?? 0
        state = Int(a.field(root, "playbackState")?.int ?? 0)
        captionsEnabled = a.field(root, "captionsEnabled")?.bool ?? false
        hasCaptions = a.field(root, "hasValidCaptionOptions")?.bool ?? false
        bundleID = a.field(md, "bundleID")?.string
        artwork = a.field(root, "imageData")?.data
        if title == nil && duration == nil { return nil }
    }

    public init(title: String?, duration: Double?, elapsed: Double, timestamp: Double, rate: Double, state: Int) {
        self.title = title
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.state = state
        captionsEnabled = false
        hasCaptions = false
    }
}

/// The TV's text-input (RTI) session: present while a text field on the TV has focus.
public struct TextSession: Sendable, Equatable {
    public let uuid: [UInt8]
    /// The field's text when the session started.
    public let text: String

    /// From a `_tiD` archive (`_tiStart` reply, `_tiStarted` event): `$top.sessionUUID`
    /// (16 bytes) and `$top.documentState.docSt.contextBeforeInput`.
    public init?(archive bytes: [UInt8]) {
        guard let a = try? KeyedArchive(bytes) else { return nil }
        let top = Plist.dict(a.top)
        guard let uuid = a.resolve(top["sessionUUID"]).flatMap({ $0.data ?? $0["NS.uuidbytes"]?.data }), uuid.count == 16
        else { return nil }
        self.uuid = uuid
        text = a.path(top, "documentState", "docSt", "contextBeforeInput")?.string ?? ""
    }

    public init(uuid: [UInt8], text: String) {
        self.uuid = uuid
        self.text = text
    }
}

/// Builds `RTITextOperations` archives (the `_tiD` of a `_tiC` event).
enum RTI {
    /// `textToAssert` replaces the field's whole text; `insertion` types at the cursor.
    static func operations(session: [UInt8], replaceWith text: String? = nil, insert: String? = nil) -> [UInt8] {
        var b = ArchiveBuilder()
        let uuid = b.object("NSUUID", [("NS.uuidbytes", .data(session))])
        var out: [(String, Plist)] = []
        if let insert { out.append(("insertionText", .uid(b.add(.string(insert))))) }
        let output = b.object("TIKeyboardOutput", out)
        var fields: [(String, Plist)] = [("keyboardOutput", .uid(output)), ("targetSessionUUID", .uid(uuid))]
        if let text { fields.append(("textToAssert", .uid(b.add(.string(text))))) }
        let ops = b.object("RTITextOperations", fields)
        return b.archive(top: [("textOperations", ops)], archiver: "RTIKeyedArchiver")
    }
}

/// Writes NSKeyedArchiver-shaped archives: `$objects[0]` is "$null", objects refer to
/// each other and to their class descriptions by UID.
struct ArchiveBuilder {
    private(set) var objects: [Plist] = [.string("$null")]
    private var classes: [String: Int] = [:]

    mutating func add(_ p: Plist) -> Int {
        objects.append(p)
        return objects.count - 1
    }

    mutating func object(_ className: String, _ fields: [(String, Plist)]) -> Int {
        let c: Int
        if let existing = classes[className] {
            c = existing
        } else {
            c = add(.dict([("$classname", .string(className)), ("$classes", .array([.string(className), .string("NSObject")]))]))
            classes[className] = c
        }
        return add(.dict(fields + [("$class", .uid(c))]))
    }

    func archive(top: [(String, Int)], archiver: String = "NSKeyedArchiver") -> [UInt8] {
        Plist.dict([
            ("$version", .int(100000)),
            ("$archiver", .string(archiver)),
            ("$top", .dict(top.map { ($0.0, .uid($0.1)) })),
            ("$objects", .array(objects)),
        ]).encode()
    }
}
