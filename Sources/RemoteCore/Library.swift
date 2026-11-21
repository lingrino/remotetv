import Foundation

/// An app installed on the Apple TV (`FetchLaunchableApplicationsEvent`).
public struct TVApp: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    /// The TV's own icon (PNG, tvOS's 5:3 shape), when asked for.
    public var icon: [UInt8]?
    public var id: String { bundleID }
}

/// One "Up Next" (continue watching) entry, from `FetchUpNextInfoEvent`: an archived
/// `TVRCUpNextInfo` {actionURL, service, reason, progress, mediaInfo: TVRCMediaInfo
/// {title, showTitle, seasonNumber, episodeNumber, imageURLTemplate, kind}}.
public struct UpNextItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Show title, or "S2 · E5", or nil.
    public let subtitle: String?
    /// "Hulu", "Apple TV+"…
    public let service: String?
    /// "New Episode", "Resume"…
    public let reason: String?
    /// 0…1 watched, when known.
    public let progress: Double?
    /// Opens the item in its app and plays it (`_launchApp {_urlS}`).
    public let actionURL: String?
    /// mzstatic template with {w}, {h}, {f}.
    public let imageTemplate: String?

    public func imageURL(width: Int, height: Int) -> URL? {
        guard let t = imageTemplate else { return nil }
        return URL(string: t.replacing("{w}", with: "\(width)").replacing("{h}", with: "\(height)")
            .replacing("{f}", with: "jpg").replacing("{c}", with: ""))
    }

    public init?(archive bytes: [UInt8]) {
        guard let a = try? KeyedArchive(bytes), let root = a.root else { return nil }
        let mi = a.field(root, "mediaInfo")
        guard let title = a.field(mi, "title")?.string ?? a.field(mi, "showTitle")?.string else { return nil }
        self.title = title
        id = a.field(mi, "identifier")?.string ?? title
        var sub: String?
        if let show = a.field(mi, "showTitle")?.string, show != title { sub = show }
        // Season/episode come as integers or reals depending on the item.
        let season = a.field(mi, "seasonNumber")?.double.map(Int.init)
        let episode = a.field(mi, "episodeNumber")?.double.map(Int.init)
        if let e = episode {
            sub = [sub, season.map { "S\($0) · E\(e)" } ?? "E\(e)"].compactMap { $0 }.joined(separator: " · ")
        }
        subtitle = sub
        service = a.field(root, "service")?.string
        reason = a.field(root, "reason")?.string
        progress = a.field(root, "progress")?.double
        actionURL = a.field(a.field(root, "actionURL"), "NS.relative")?.string
        imageTemplate = a.field(mi, "imageURLTemplate")?.string
    }
}

extension Remote {
    /// The TV's installed apps, in its own order. With `icons`, one request per app
    /// (each carries its PNG; asking app by app keeps the order the TV lists them in).
    public func fetchApps(icons: Bool, completion: @escaping @MainActor ([TVApp]) -> Void) {
        guard icons else {
            raw("FetchLaunchableApplicationsEvent", [:]) { reply, _ in
                var apps: [TVApp] = []
                if case .dict(let d)? = reply?["_c"] {
                    for (k, v) in d { if let n = v.string { apps.append(TVApp(bundleID: k, name: n)) } }
                }
                completion(apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            return
        }
        // Page 0 tells the count; then the rest, one app per request, all in flight.
        page(0) { [weak self] first, count in
            guard let self else { return }
            guard count > 1 else { return completion(first) }
            var pages = [[TVApp]?](repeating: nil, count: count)
            pages[0] = first
            var left = count - 1
            for i in 1..<count {
                self.page(i) { apps, _ in
                    pages[i] = apps
                    left -= 1
                    if left == 0 { completion(pages.flatMap { $0 ?? [] }) }
                }
            }
        }
    }

    private func page(_ i: Int, _ done: @escaping @MainActor ([TVApp], Int) -> Void) {
        raw("FetchLaunchableApplicationsEvent", ["IncludeAppMetadataKey": .bool(true), "UsePNG": .bool(true),
                                                 "AppRangeStartingIndexKey": .int(Int64(i)), "AppRangeCountKey": .int(1)]) { reply, _ in
            var apps: [TVApp] = []
            if case .dict(let infos)? = reply?["_c"]?["AppInfos"] {
                for (k, v) in infos {
                    apps.append(TVApp(bundleID: k, name: v["LocalizedAppName"]?.string ?? k, icon: v["ImageKey"]?.data))
                }
            }
            done(apps, Int(reply?["_c"]?["AppCountKey"]?.int ?? 0))
        }
    }

    /// Continue-watching items, in the TV's order.
    public func fetchUpNext(completion: @escaping @MainActor ([UpNextItem]) -> Void) {
        raw("FetchUpNextInfoEvent", [:]) { reply, _ in
            let items = reply?["_c"]?["UpNextInfosKey"]?.array?.compactMap { $0.data.flatMap(UpNextItem.init(archive:)) } ?? []
            completion(items)
        }
    }

    /// Opens a URL on the TV (a deep link: plays an Up Next item in its app).
    public func open(url: String) {
        raw("_launchApp", ["_urlS": .string(url)])
    }
}
