import AppKit
import RemoteCore

/// The sidebar: a Liquid Glass panel that slides out of the remote's right edge (⌃⌘S or
/// the title-bar button). The remote itself never changes. Top: what's playing (artwork,
/// title, app). Below: Up Next (continue watching; click plays) and Apps (the TV's own
/// icons; click opens), one at a time. Built on first open; nothing at launch.
final class Sidebar: NSView {
    static let width: CGFloat = 320
    static let inset: CGFloat = 8

    var onPlay: ((UpNextItem) -> Void)?
    var onLaunch: ((TVApp) -> Void)?
    var onTab: ((Int) -> Void)?

    private let glass = NSGlassEffectView()
    private let body = Flipped()
    private let card = NowPlayingCard()
    private let tabs = NSSegmentedControl(labels: ["Up Next", "Apps"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let upNext = UpNextList()
    private let apps = AppGrid()
    private let empty = NSTextField(labelWithString: "")
    private var hasCard = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = 22
        addSubview(glass)
        body.frame = bounds
        body.autoresizingMask = [.width, .height]
        glass.contentView = body

        body.addSubview(card)
        tabs.selectedSegment = 0
        tabs.segmentStyle = .automatic
        tabs.controlSize = .regular
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.refusesFirstResponder = true
        body.addSubview(tabs)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        body.addSubview(scroll)

        upNext.onPick = { [weak self] item in self?.onPlay?(item) }
        apps.onPick = { [weak self] app in self?.onLaunch?(app) }

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        body.addSubview(empty)
        layoutBody()
        showTab()
    }

    required init?(coder: NSCoder) { fatalError() }

    var tab: Int {
        get { tabs.selectedSegment }
        set { tabs.selectedSegment = newValue; showTab() }
    }

    func setNowPlaying(_ np: NowPlaying?, app: TVApp?) {
        let show = np != nil
        card.show(np, app: app)
        if show != hasCard {
            hasCard = show
            layoutBody()
        }
    }

    /// nil while loading; `failed` when the TV couldn't list it.
    func setUpNext(_ items: [UpNextItem]?, failed: Bool = false) {
        upNextFailed = failed
        upNext.set(items ?? [])
        if tab == 0 { showTab(loading: items == nil && !failed) }
    }

    private var upNextFailed = false

    func setApps(_ list: [TVApp]?) {
        apps.set(list ?? [])
        if tab == 1 { showTab(loading: list == nil) }
    }

    private func layoutBody() {
        let w = bounds.width, pad: CGFloat = 14
        card.isHidden = !hasCard
        card.frame = NSRect(x: pad, y: pad, width: w - 2 * pad, height: NowPlayingCard.height)
        let tabsY = hasCard ? card.frame.maxY + 14 : pad
        tabs.frame = NSRect(x: pad, y: tabsY, width: w - 2 * pad, height: 24)
        tabs.setWidth((w - 2 * pad) / 2 - 2, forSegment: 0)
        tabs.setWidth((w - 2 * pad) / 2 - 2, forSegment: 1)
        let listY = tabs.frame.maxY + 10
        scroll.frame = NSRect(x: pad - 6, y: listY, width: w - 2 * pad + 12, height: bounds.height - listY - 8)
        empty.frame = NSRect(x: pad, y: listY + 40, width: w - 2 * pad, height: 18)
        sizeDocument()
    }

    @objc private func tabChanged() {
        showTab()
        onTab?(tabs.selectedSegment)
    }

    private func showTab(loading: Bool = false) {
        let doc: NSView = tab == 0 ? upNext : apps
        if scroll.documentView !== doc {
            scroll.documentView = doc
            doc.scroll(.zero)
        }
        sizeDocument()
        let count = tab == 0 ? upNext.count : apps.count
        empty.stringValue = loading ? "Loading…"
            : tab == 0 ? (upNextFailed ? "Up Next isn't available right now" : "Nothing in Up Next") : "No apps"
        empty.isHidden = count > 0
    }

    private func sizeDocument() {
        let w = scroll.frame.width
        upNext.frame = NSRect(x: 0, y: 0, width: w, height: max(upNext.height(width: w), scroll.frame.height))
        apps.frame = NSRect(x: 0, y: 0, width: w, height: max(apps.height(width: w), scroll.frame.height))
    }
}

// MARK: - Now playing

final class NowPlayingCard: NSView {
    static let height: CGFloat = 74
    private let art = ImageBox()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        art.cornerRadius = 9
        addSubview(art)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        source.font = .systemFont(ofSize: 11)
        source.textColor = .tertiaryLabelColor
        source.lineBreakMode = .byTruncatingTail
        for v in [title, detail, source] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ np: NowPlaying?, app: TVApp?) {
        guard let np else { return }
        let w = bounds.width
        let artW: CGFloat = 132
        art.frame = NSRect(x: 0, y: 0, width: artW, height: NowPlayingCard.height)
        if let a = np.artwork, let img = NSImage(data: Data(a)) {
            art.set(img, fill: true)
        } else if let i = app?.icon, let img = NSImage(data: Data(i)) {
            art.set(img, fill: false)
        } else {
            art.set(nil, fill: false)
        }
        let x = artW + 12, tw = w - x
        title.stringValue = np.title ?? "Playing"
        let th = min(34, title.sizeThatFits(NSSize(width: tw, height: 40)).height)
        title.frame = NSRect(x: x, y: 2, width: tw, height: th)
        detail.stringValue = np.subtitle ?? (np.isPlaying ? "Playing" : "Paused")
        detail.frame = NSRect(x: x, y: title.frame.maxY + 3, width: tw, height: 15)
        source.stringValue = app?.name ?? ""
        source.frame = NSRect(x: x, y: detail.frame.maxY + 1, width: tw, height: 15)
    }
}

// MARK: - Up Next

final class UpNextList: NSView {
    var onPick: ((UpNextItem) -> Void)?
    private var rows: [UpNextRow] = []
    static let rowHeight: CGFloat = 66
    override var isFlipped: Bool { true }

    var count: Int { rows.count }

    func set(_ items: [UpNextItem]) {
        guard items.map(\.id) != rows.map(\.item.id) else { return }
        for r in rows { r.removeFromSuperview() }
        rows = items.map { item in
            let r = UpNextRow(item: item)
            r.onClick = { [weak self] in self?.onPick?(item) }
            addSubview(r)
            return r
        }
        needsLayout = true
    }

    func height(width: CGFloat) -> CGFloat { CGFloat(rows.count) * UpNextList.rowHeight + 4 }

    override func layout() {
        super.layout()
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * UpNextList.rowHeight, width: bounds.width, height: UpNextList.rowHeight)
        }
    }
}

final class UpNextRow: HoverView {
    let item: UpNextItem
    private let thumb = ImageBox()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = CALayer()

    init(item: UpNextItem) {
        self.item = item
        super.init(frame: .zero)
        thumb.cornerRadius = 7
        addSubview(thumb)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.cell?.wraps = true
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        addSubview(title)
        addSubview(detail)
        title.stringValue = item.title
        detail.stringValue = [item.subtitle, item.reason].compactMap { $0 }.joined(separator: " · ")
        progress.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        progress.cornerRadius = 1
        thumb.layer?.addSublayer(progress)
        if let url = item.imageURL(width: 320, height: 180) {
            Images.shared.load(url) { [weak self] img in self?.thumb.set(img, fill: true) }
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel("Play \(item.title)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, tw: CGFloat = 96, th: CGFloat = 54
        thumb.frame = NSRect(x: 6, y: (h - th) / 2, width: tw, height: th)
        if let p = item.progress, p > 0 {
            progress.isHidden = false
            progress.frame = CGRect(x: 6, y: 5, width: (tw - 12) * min(1, p), height: 2)   // layer coords: bottom-left
        } else {
            progress.isHidden = true
        }
        let x = thumb.frame.maxX + 10, w = bounds.width - x - 6
        let titleH = min(32, title.sizeThatFits(NSSize(width: w, height: 40)).height)
        let block = titleH + 2 + 14
        title.frame = NSRect(x: x, y: (h - block) / 2, width: w, height: titleH)
        detail.frame = NSRect(x: x, y: title.frame.maxY + 2, width: w, height: 14)
    }
}

// MARK: - Apps

final class AppGrid: NSView {
    var onPick: ((TVApp) -> Void)?
    private var tiles: [AppTile] = []
    static let columns = 3
    override var isFlipped: Bool { true }

    var count: Int { tiles.count }

    func set(_ apps: [TVApp]) {
        guard apps.map(\.id) != tiles.map(\.app.id) || zip(apps, tiles).contains(where: { ($0.icon == nil) != ($1.app.icon == nil) })
        else { return }
        for t in tiles { t.removeFromSuperview() }
        tiles = apps.map { app in
            let t = AppTile(app: app)
            t.onClick = { [weak self] in self?.onPick?(app) }
            addSubview(t)
            return t
        }
        needsLayout = true
    }

    private func metrics(_ width: CGFloat) -> (w: CGFloat, h: CGFloat, gap: CGFloat) {
        let gap: CGFloat = 6
        let w = (width - 12 - gap * CGFloat(AppGrid.columns - 1)) / CGFloat(AppGrid.columns)
        return (w, w * 0.6 + 22, gap)
    }

    func height(width: CGFloat) -> CGFloat {
        let m = metrics(width)
        let rows = (tiles.count + AppGrid.columns - 1) / AppGrid.columns
        return CGFloat(rows) * (m.h + m.gap) + 4
    }

    override func layout() {
        super.layout()
        let m = metrics(bounds.width)
        for (i, t) in tiles.enumerated() {
            let c = i % AppGrid.columns, r = i / AppGrid.columns
            t.frame = NSRect(x: 6 + CGFloat(c) * (m.w + m.gap), y: CGFloat(r) * (m.h + m.gap), width: m.w, height: m.h)
        }
    }
}

final class AppTile: HoverView {
    let app: TVApp
    private let icon = ImageBox()
    private let name = NSTextField(labelWithString: "")

    init(app: TVApp) {
        self.app = app
        super.init(frame: .zero)
        icon.cornerRadius = 8
        addSubview(icon)
        if let d = app.icon, let img = NSImage(data: Data(d)) { icon.set(img, fill: true) }
        name.stringValue = app.name
        name.font = .systemFont(ofSize: 10.5)
        name.textColor = .secondaryLabelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(app.name)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width - 8
        icon.frame = NSRect(x: 4, y: 4, width: w, height: w * 0.6)
        name.frame = NSRect(x: 2, y: icon.frame.maxY + 3, width: bounds.width - 4, height: 14)
    }
}

// MARK: - Building blocks

final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// A clickable area with a soft hover/press background, for list rows and tiles.
class HoverView: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressing = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressing = true }

    override func mouseUp(with event: NSEvent) {
        pressing = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || pressing else { return }
        NSColor.labelColor.withAlphaComponent(pressing ? 0.12 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// An image in a rounded, clipped box: aspect-fill for artwork, aspect-fit on a tinted
/// background for icons, a quiet placeholder when empty.
final class ImageBox: NSView {
    var cornerRadius: CGFloat = 8 { didSet { layer?.cornerRadius = cornerRadius } }
    private var hasImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.contentsGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = hasImage && layer?.contentsGravity == .resizeAspectFill
            ? nil : NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
    }

    func set(_ image: NSImage?, fill: Bool) {
        hasImage = image != nil
        layer?.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsDisplay = true
    }
}

/// Up Next thumbnails from Apple's image CDN, kept in memory for the app's lifetime
/// (a few dozen small JPEGs).
@MainActor
final class Images {
    static let shared = Images()
    private var cache: [URL: NSImage] = [:]
    private var waiting: [URL: [(NSImage) -> Void]] = [:]

    func load(_ url: URL, _ done: @escaping (NSImage) -> Void) {
        if let img = cache[url] { return done(img) }
        if waiting[url] != nil { waiting[url]?.append(done); return }
        waiting[url] = [done]
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let callbacks = self.waiting.removeValue(forKey: url) ?? []
                    guard let img else { return }
                    self.cache[url] = img
                    for c in callbacks { c(img) }
                }
            }
        }.resume()
    }
}
