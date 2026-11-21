import AppKit
import RemoteCore

/// The window's content: header (TV name, status, power), clickpad, skip, transport row,
/// volume, and the pairing panel in place of the controls when pairing. Fixed layout in a
/// flipped coordinate space; all sizes come from `Theme`.
final class RemoteView: NSView {
    // Header
    let title = NSButton(title: "", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let power = GlassButton(symbol: "power", label: "Power", diameter: 30, pointSize: 13)

    // Controls
    let pad = ClickPad(diameter: Theme.padDiameter)
    let skipBack = IconButton(symbol: "gobackward.10", label: "Back 10 seconds")
    let skipForward = IconButton(symbol: "goforward.10", label: "Forward 10 seconds")
    let playPause = GlassButton(symbol: "playpause.fill", label: "Play/Pause")
    let back = GlassButton(symbol: "chevron.left", label: "Back", diameter: Theme.buttonDiameter + 10, pointSize: 24)
    let home = GlassButton(symbol: "tv", label: "TV")
    let volume = SplitPill(width: 172, height: 48, first: "minus", second: "plus", middle: "speaker.wave.2.fill",
                           labels: ("Volume Down", "Volume Up"))

    let pairing = PairingView()
    private lazy var controls: [NSView] = [pad, skipBack, skipForward, playPause, back, home, volume]

    static let height: CGFloat = 476

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Key events go to the controller (see AppDelegate.key).
    var onKey: ((NSEvent, Bool) -> Bool)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.width, height: RemoteView.height))
        let w = Theme.width

        title.isBordered = false
        title.refusesFirstResponder = true   // Space/Return must reach the remote, not this
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Choose Apple TV")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        title.imagePosition = .imageTrailing
        title.imageHugsTitle = true
        title.frame = NSRect(x: 80, y: 4, width: w - 160, height: 22)
        title.alignment = .center
        addSubview(title)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 26, width: w - 32, height: 16)
        addSubview(status)

        power.frame.origin = NSPoint(x: w - 30 - 10, y: 1)
        addSubview(power)

        let padTop: CGFloat = 50
        pad.frame.origin = NSPoint(x: (w - Theme.padDiameter) / 2, y: padTop)
        addSubview(pad)
        skipBack.frame.origin = NSPoint(x: 14, y: padTop + Theme.padDiameter - 34)
        skipForward.frame.origin = NSPoint(x: w - 14 - 36, y: padTop + Theme.padDiameter - 34)
        addSubview(skipBack)
        addSubview(skipForward)

        let rowCenter = padTop + Theme.padDiameter + 26 + back.frame.height / 2
        back.frame.origin = NSPoint(x: (w - back.frame.width) / 2, y: rowCenter - back.frame.height / 2)
        playPause.frame.origin = NSPoint(x: w / 2 - 88 - playPause.frame.width / 2, y: rowCenter - playPause.frame.height / 2)
        home.frame.origin = NSPoint(x: w / 2 + 88 - home.frame.width / 2, y: rowCenter - home.frame.height / 2)
        for v in [playPause, back, home] { addSubview(v) }

        volume.frame.origin = NSPoint(x: (w - volume.frame.width) / 2, y: rowCenter + back.frame.height / 2 + 24)
        addSubview(volume)

        pairing.frame = NSRect(x: 0, y: padTop, width: w, height: RemoteView.height - padTop)
        pairing.isHidden = true
        addSubview(pairing)
    }

    required init?(coder: NSCoder) { fatalError() }

    var showsPairing: Bool {
        get { !pairing.isHidden }
        set {
            pairing.isHidden = !newValue
            for v in controls { v.isHidden = newValue }
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event, true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKey?(event, false) != true { super.keyUp(with: event) }
    }
}

/// Pairing: pick an Apple TV, then type the PIN it shows.
final class PairingView: NSView {
    let heading = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let pin = NSTextField()
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let list = NSStackView()
    var onPick: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        pin.font = .monospacedDigitSystemFont(ofSize: 30, weight: .medium)
        pin.alignment = .center
        pin.placeholderString = "0000"
        pin.bezelStyle = .roundedBezel
        pin.focusRingType = .none
        cancel.bezelStyle = .push
        list.orientation = .vertical
        list.spacing = 8
        list.alignment = .centerX
        list.setHuggingPriority(.required, for: .vertical)
        for v in [heading, detail, pin, cancel, list] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        heading.frame = NSRect(x: 16, y: 24, width: w - 32, height: 24)
        detail.frame = NSRect(x: 28, y: 54, width: w - 56, height: 48)
        pin.frame = NSRect(x: (w - 140) / 2, y: 116, width: 140, height: 46)
        cancel.frame = NSRect(x: (w - 100) / 2, y: 178, width: 100, height: 30)
        let h = list.fittingSize.height
        list.frame = NSRect(x: 24, y: 120, width: w - 48, height: h)
    }

    /// Step 1: the Apple TVs found on the network.
    func showDevices(_ names: [String], paired: Set<String>) {
        heading.stringValue = "Pair with an Apple TV"
        detail.stringValue = names.isEmpty ? "Looking for Apple TVs on your network…" : "Choose the Apple TV to control."
        pin.isHidden = true
        cancel.isHidden = true
        list.isHidden = false
        for v in list.arrangedSubviews { v.removeFromSuperview() }
        for name in names {
            let b = NSButton(title: paired.contains(name) ? "\(name) (paired)" : name, target: self, action: #selector(picked(_:)))
            b.bezelStyle = .glass
            b.controlSize = .large
            b.identifier = NSUserInterfaceItemIdentifier(name)
            b.widthAnchor.constraint(equalToConstant: 200).isActive = true
            list.addArrangedSubview(b)
        }
        needsLayout = true
    }

    /// Step 2: the TV shows a PIN.
    func showPIN(for name: String, error: String?) {
        heading.stringValue = "Enter the Code"
        detail.stringValue = error ?? "Type the 4-digit code shown on “\(name)”."
        detail.textColor = error == nil ? .secondaryLabelColor : .systemRed
        list.isHidden = true
        pin.isHidden = false
        pin.isEnabled = true
        pin.stringValue = ""
        cancel.isHidden = false
        window?.makeFirstResponder(pin)
    }

    func showWorking(_ text: String) {
        detail.stringValue = text
        detail.textColor = .secondaryLabelColor
        pin.isEnabled = false
    }

    @objc private func picked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onPick?(name)
    }
}
