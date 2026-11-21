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

/// The volume capsule: − | mute | +, three hit zones in one glass pill. The middle
/// shows the speaker (slashed when muted) and is dimmed when mute isn't available.
final class VolumePill: NSView {
    enum Part { case down, mute, up }
    var onPress: ((Part, _ down: Bool) -> Void)?
    private let glass = NSGlassEffectView()
    private let speaker = NSImageView()
    private var active: Part?

    var muted = false { didSet { if muted != oldValue { updateSpeaker() } } }
    var muteAvailable = false { didSet { if muteAvailable != oldValue { updateSpeaker() } } }

    init(width: CGFloat, height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.frame = bounds
        glass.cornerRadius = height / 2
        glass.effectIsInteractive = true
        addSubview(glass)
        let cfg = NSImage.SymbolConfiguration(pointSize: Theme.symbolSize - 2, weight: .semibold)
        for (i, (name, label)) in [("minus", "Volume Down"), ("plus", "Volume Up")].enumerated() {
            let v = NSImageView(frame: NSRect(x: i == 0 ? 2 : width - height - 2, y: 0, width: height, height: height))
            v.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(cfg)
            v.contentTintColor = .labelColor
            v.imageScaling = .scaleNone
            addSubview(v)
        }
        speaker.frame = NSRect(x: (width - height) / 2, y: 0, width: height, height: height)
        speaker.imageScaling = .scaleNone
        addSubview(speaker)
        updateSpeaker()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateSpeaker() {
        speaker.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                accessibilityDescription: muted ? "Unmute" : "Mute")?
            .withSymbolConfiguration(.init(pointSize: Theme.symbolSize - 3, weight: .regular))
        speaker.contentTintColor = muted ? .controlAccentColor : (muteAvailable ? .secondaryLabelColor : .quaternaryLabelColor)
        toolTip = muteAvailable ? (muted ? "Unmute" : "Mute") : "Volume"
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func part(at x: CGFloat) -> Part {
        let third = bounds.width / 3
        return x < third ? .down : (x > 2 * third ? .up : .mute)
    }

    override func mouseDown(with event: NSEvent) {
        let p = part(at: convert(event.locationInWindow, from: nil).x)
        if p == .mute && !muteAvailable { return }
        active = p
        glass.tintColor = NSColor.labelColor.withAlphaComponent(0.12)
        onPress?(p, true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = active else { return }
        active = nil
        glass.tintColor = nil
        onPress?(p, false)
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
