import AppKit

/// Look of the remote. One place for sizes and colors.
enum Theme {
    static let width: CGFloat = 300
    static let padDiameter: CGFloat = 232
    static let buttonDiameter: CGFloat = 62
    static let symbolSize: CGFloat = 20
    static let gap: CGFloat = 22
}

/// Shared down/up plumbing for remote controls: a press is "down" on mouse-down and "up"
/// on mouse-up (wherever the mouse is then), so holding a button holds it on the TV.
class PressView: NSView {
    var onPress: ((Bool) -> Void)?
    private(set) var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressChanged()
        onPress?(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        pressChanged()
        onPress?(false)
    }

    func pressChanged() {}
}

/// A Liquid Glass circle (or capsule) with an SF Symbol: the remote's buttons.
final class GlassButton: PressView {
    private let glass = NSGlassEffectView()
    private let icon = NSImageView()
    private let pointSize: CGFloat

    init(symbol: String, label: String, diameter: CGFloat = Theme.buttonDiameter, pointSize: CGFloat = Theme.symbolSize) {
        self.pointSize = pointSize
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = diameter / 2
        glass.effectIsInteractive = true
        addSubview(glass)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        icon.contentTintColor = .labelColor
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        icon.imageScaling = .scaleNone
        addSubview(icon)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError() }

    var symbol: String = "" {
        didSet {
            guard symbol != oldValue else { return }
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel())?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        }
    }

    var tint: NSColor? {
        get { icon.contentTintColor }
        set { icon.contentTintColor = newValue ?? .labelColor }
    }

    override func pressChanged() {
        glass.tintColor = pressed ? NSColor.labelColor.withAlphaComponent(0.18) : nil
    }
}

/// Two buttons in one capsule (volume − / +), split down the middle.
final class SplitPill: NSView {
    var onPress: ((_ second: Bool, _ down: Bool) -> Void)?
    private let glass = NSGlassEffectView()
    private var active: Bool?   // which half is held (false = first, true = second)

    init(width: CGFloat, height: CGFloat, first: String, second: String, middle: String?, labels: (String, String)) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.frame = bounds
        glass.cornerRadius = height / 2
        glass.effectIsInteractive = true
        addSubview(glass)
        let cfg = NSImage.SymbolConfiguration(pointSize: Theme.symbolSize - 2, weight: .semibold)
        for (i, name) in [first, second].enumerated() {
            let v = NSImageView(frame: NSRect(x: i == 0 ? 0 : width - height, y: 0, width: height, height: height))
            v.image = NSImage(systemSymbolName: name, accessibilityDescription: i == 0 ? labels.0 : labels.1)?.withSymbolConfiguration(cfg)
            v.contentTintColor = .labelColor
            v.imageScaling = .scaleNone
            addSubview(v)
        }
        if let middle {
            let v = NSImageView(frame: NSRect(x: (width - height) / 2, y: 0, width: height, height: height))
            v.image = NSImage(systemSymbolName: middle, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Theme.symbolSize - 4, weight: .regular))
            v.contentTintColor = .secondaryLabelColor
            v.imageScaling = .scaleNone
            addSubview(v)
        }
        toolTip = "\(labels.0) / \(labels.1)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let second = p.x >= bounds.midX
        active = second
        glass.tintColor = NSColor.labelColor.withAlphaComponent(0.12)
        onPress?(second, true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let second = active else { return }
        active = nil
        glass.tintColor = nil
        onPress?(second, false)
    }
}

/// A small borderless symbol button (skip ±10 s).
final class IconButton: PressView {
    private let icon = NSImageView()

    init(symbol: String, label: String, size: CGFloat = 36) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = bounds
        icon.imageScaling = .scaleNone
        addSubview(icon)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError() }

    override func pressChanged() {
        icon.contentTintColor = pressed ? .labelColor : .secondaryLabelColor
    }
}
