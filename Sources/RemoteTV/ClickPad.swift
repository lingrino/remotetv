import AppKit
import RemoteCore

/// The Siri Remote's clickpad as a big glass circle: click the center to select, the
/// edges (wedges) to move. Holding a click holds the button on the TV (scrolling lists,
/// long-press menus). A two-finger swipe on the trackpad over the pad is a swipe on the
/// TV's touch surface (scrubbing, fast scrolling).
final class ClickPad: NSView {
    /// Button down/up.
    var onButton: ((Button, Bool) -> Void)?
    /// Touch surface: (x, y) in 0…1000, phase 1 press / 3 move / 4 release.
    var onTouch: ((Double, Double, Int) -> Void)?

    private let glass = NSGlassEffectView()
    private let overlay = Overlay()
    private var held: Button?
    private var touch: (x: Double, y: Double)?

    /// Center (select) radius as a fraction of the pad radius.
    private static let inner: CGFloat = 0.36

    init(diameter: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        glass.frame = bounds
        glass.cornerRadius = diameter / 2
        glass.effectIsInteractive = true
        overlay.frame = bounds
        overlay.inner = ClickPad.inner
        glass.contentView = overlay
        addSubview(glass)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Clickpad")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Which button a point (view coordinates) is on; nil outside the circle.
    func button(at p: NSPoint) -> Button? {
        let r = bounds.width / 2
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        let d = (dx * dx + dy * dy).squareRoot() / r
        if d > 1 { return nil }
        if d <= ClickPad.inner { return .select }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .up : .down
    }

    override func mouseDown(with event: NSEvent) {
        guard let b = button(at: convert(event.locationInWindow, from: nil)) else { return }
        held = b
        overlay.highlight = b
        onButton?(b, true)
    }

    override func mouseUp(with event: NSEvent) { release() }

    private func release() {
        guard let b = held else { return }
        held = nil
        overlay.highlight = nil
        onButton?(b, false)
    }

    /// Releases a held click or touch (the window lost focus mid-press).
    func cancel() {
        release()
        if let t = touch {
            onTouch?(t.x, t.y, 4)
            touch = nil
            overlay.swiping = false
        }
    }

    // MARK: - Trackpad swipes

    /// Trackpad points → TV touch units (the pad is 1000 wide): about a full pad per
    /// comfortable two-finger swipe.
    private static let touchScale = 2.5

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        // Physical finger motion, right/down positive, whatever the scrolling preference.
        let sign: Double = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = sign * event.scrollingDeltaX * ClickPad.touchScale
        let dy = sign * event.scrollingDeltaY * ClickPad.touchScale
        if event.phase.contains(.began) || (touch == nil && event.phase.contains(.changed)) {
            touch = (500, 500)
            onTouch?(500, 500, 1)
            overlay.swiping = true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if let t = touch { onTouch?(t.x, t.y, 4) }
            touch = nil
            overlay.swiping = false
            return
        }
        guard var t = touch, event.phase.contains(.changed) else { return }
        let nx = t.x + dx, ny = t.y + dy
        if nx < 0 || nx > 1000 || ny < 0 || ny > 1000 {
            // The virtual finger reached the pad's edge: lift it there and put it down at
            // the center with the next movement, so a long swipe keeps going (pinning it
            // at the edge would stall). Never a lift without motion: that would be a tap.
            onTouch?(min(1000, max(0, nx)), min(1000, max(0, ny)), 4)
            touch = nil
            return
        }
        t.x = nx
        t.y = ny
        touch = t
        onTouch?(t.x, t.y, 3)
    }

    /// Chevrons, the center ring and the pressed-wedge highlight, drawn in one view.
    final class Overlay: NSView {
        var inner: CGFloat = 0.36
        var highlight: Button? { didSet { if highlight != oldValue { needsDisplay = true } } }
        var swiping = false { didSet { if swiping != oldValue { needsDisplay = true } } }

        private static let chevrons: [(Button, String)] = [
            (.up, "chevron.up"), (.down, "chevron.down"), (.left, "chevron.left"), (.right, "chevron.right"),
        ]
        /// (normal, highlighted) per direction; the palette colors are dynamic, so they
        /// follow light/dark mode at draw time.
        private lazy var images: [Button: (NSImage, NSImage)] = {
            let size = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            let normal = size.applying(.init(paletteColors: [.secondaryLabelColor]))
            let lit = size.applying(.init(paletteColors: [.labelColor]))
            var out: [Button: (NSImage, NSImage)] = [:]
            for (b, name) in Overlay.chevrons {
                guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                      let n = img.withSymbolConfiguration(normal), let l = img.withSymbolConfiguration(lit) else { continue }
                out[b] = (n, l)
            }
            return out
        }()

        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the pad handles events

        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.width / 2
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let ir = r * inner

            if let h = highlight {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                if h == .select {
                    NSBezierPath(ovalIn: NSRect(x: c.x - ir, y: c.y - ir, width: 2 * ir, height: 2 * ir)).fill()
                } else {
                    let mid: CGFloat = switch h { case .right: 0; case .up: 90; case .left: 180; default: 270 }
                    let p = NSBezierPath()
                    p.appendArc(withCenter: c, radius: r, startAngle: mid - 45, endAngle: mid + 45)
                    p.appendArc(withCenter: c, radius: ir, startAngle: mid + 45, endAngle: mid - 45, clockwise: true)
                    p.close()
                    p.fill()
                }
            }

            // Center ring.
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ir, y: c.y - ir, width: 2 * ir, height: 2 * ir))
            ring.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(swiping ? 0.35 : 0.18).setStroke()
            ring.stroke()

            // Chevrons, halfway between the ring and the rim.
            let at = (r + ir) / 2
            for (b, _) in Overlay.chevrons {
                guard let pair = images[b] else { continue }
                let img = b == highlight ? pair.1 : pair.0
                let s = img.size
                let o: NSPoint = switch b {
                case .up: NSPoint(x: c.x, y: c.y + at)
                case .down: NSPoint(x: c.x, y: c.y - at)
                case .left: NSPoint(x: c.x - at, y: c.y)
                default: NSPoint(x: c.x + at, y: c.y)
                }
                img.draw(in: NSRect(x: o.x - s.width / 2, y: o.y - s.height / 2, width: s.width, height: s.height))
            }
        }
    }
}
