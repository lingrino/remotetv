import AppKit
import RemoteCore

/// The window's content, top to bottom: TV name (menu), now-playing strip (title +
/// scrubber, or the text field when the TV wants text), clickpad with skip ±10 in its
/// lower corners, Play/Pause · Back · TV, then Power · volume · Captions. The pairing
/// panel replaces everything below the name while pairing. Fixed layout, flipped
/// coordinates; sizes from `Theme`.
final class RemoteView: NSView {
    let title = NSButton(title: "", target: nil, action: nil)
    let sidebarButton = NSButton(title: "", target: nil, action: nil)
    let strip = NowPlayingStrip(frame: NSRect(x: 0, y: 28, width: Theme.width, height: 46))
    let text = TextBar(frame: NSRect(x: 18, y: 34, width: Theme.width - 36, height: 36))

    let pad = ClickPad(diameter: Theme.padDiameter)
    let skipBack = IconButton(symbol: "gobackward.10", label: "Back 10 seconds")
    let skipForward = IconButton(symbol: "goforward.10", label: "Forward 10 seconds")
    let playPause = GlassButton(symbol: "playpause.fill", label: "Play/Pause")
    let back = GlassButton(symbol: "chevron.left", label: "Back", diameter: Theme.buttonDiameter + 10, pointSize: 24)
    let home = GlassButton(symbol: "tv", label: "TV")
    let power = GlassButton(symbol: "power", label: "Sleep", diameter: 44, pointSize: 16)
    let volume = VolumePill(width: 136, height: 44)
    let captions = GlassButton(symbol: "captions.bubble", label: "Subtitles", diameter: 44, pointSize: 16)

    let pairing = PairingView()
    private lazy var controls: [NSView] = [strip, pad, skipBack, skipForward, playPause, back, home, power, volume, captions]

    static let height: CGFloat = 512

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

        sidebarButton.isBordered = false
        sidebarButton.refusesFirstResponder = true
        sidebarButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Sidebar")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        sidebarButton.contentTintColor = .secondaryLabelColor
        sidebarButton.frame = NSRect(x: w - 38, y: 3, width: 28, height: 24)
        addSubview(sidebarButton)

        addSubview(strip)
        text.isHidden = true
        addSubview(text)

        let padTop: CGFloat = 82
        pad.frame.origin = NSPoint(x: (w - Theme.padDiameter) / 2, y: padTop)
        addSubview(pad)
        skipBack.frame.origin = NSPoint(x: 14, y: padTop + Theme.padDiameter - 34)
        skipForward.frame.origin = NSPoint(x: w - 14 - 36, y: padTop + Theme.padDiameter - 34)
        addSubview(skipBack)
        addSubview(skipForward)

        let rowCenter = padTop + Theme.padDiameter + 24 + back.frame.height / 2
        back.frame.origin = NSPoint(x: (w - back.frame.width) / 2, y: rowCenter - back.frame.height / 2)
        playPause.frame.origin = NSPoint(x: w / 2 - 88 - playPause.frame.width / 2, y: rowCenter - playPause.frame.height / 2)
        home.frame.origin = NSPoint(x: w / 2 + 88 - home.frame.width / 2, y: rowCenter - home.frame.height / 2)
        for v in [playPause, back, home] { addSubview(v) }

        let bottom = rowCenter + back.frame.height / 2 + 22
        volume.frame.origin = NSPoint(x: (w - volume.frame.width) / 2, y: bottom)
        power.frame.origin = NSPoint(x: w / 2 - 96 - power.frame.width / 2, y: bottom)
        captions.frame.origin = NSPoint(x: w / 2 + 96 - captions.frame.width / 2, y: bottom)
        for v in [power, volume, captions] as [NSView] { addSubview(v) }

        pairing.frame = NSRect(x: 0, y: 50, width: w, height: RemoteView.height - 50)
        pairing.isHidden = true
        addSubview(pairing)
    }

    required init?(coder: NSCoder) { fatalError() }

    var showsPairing: Bool {
        get { !pairing.isHidden }
        set {
            pairing.isHidden = !newValue
            for v in controls { v.isHidden = newValue }
            if newValue { text.isHidden = true }
        }
    }

    /// The TV's text field mirrored here (nil: back to the now-playing strip).
    func showText(_ on: Bool) {
        text.isHidden = !on
        strip.isHidden = on || showsPairing
    }

    func setCaptions(available: Bool, on: Bool) {
        captions.alphaValue = available ? 1 : 0.35
        captions.symbol = on ? "captions.bubble.fill" : "captions.bubble"
        captions.tint = on ? .controlAccentColor : nil
        captions.setAccessibilityLabel(available ? (on ? "Subtitles On" : "Subtitles Off") : "No Subtitles")
    }

    /// Dims what the TV says won't work right now (it acknowledges every press either way).
    func setAvailability(skip: Bool, volume: Bool) {
        let a: CGFloat = 0.35
        skipBack.alphaValue = skip ? 1 : a
        skipForward.alphaValue = skip ? 1 : a
        self.volume.alphaValue = volume ? 1 : a
    }

    func setPower(asleep: Bool) {
        power.tint = asleep ? .tertiaryLabelColor : nil
        power.setAccessibilityLabel(asleep ? "Wake" : "Sleep")
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event, true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKey?(event, false) != true { super.keyUp(with: event) }
    }
}

/// Title and a scrubber for what's playing; status text ("Connecting…", "Not Playing")
/// in the title line otherwise.
final class NowPlayingStrip: NSView {
    let label = NSTextField(labelWithString: "")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let elapsed = NSTextField(labelWithString: "")
    let remaining = NSTextField(labelWithString: "")
    /// Seek requested (seconds), on release.
    var onSeek: ((Double) -> Void)?
    /// A click on the title line while it shows a status (e.g. open Privacy settings).
    var onStatusClick: (() -> Void)?
    private var showingStatus = false
    private(set) var scrubbing = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let w = frame.width
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 20, y: 0, width: w - 40, height: 16)
        addSubview(label)

        let digits = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        for l in [elapsed, remaining] {
            l.font = digits
            l.textColor = .tertiaryLabelColor
            addSubview(l)
        }
        elapsed.alignment = .right
        remaining.alignment = .left
        elapsed.frame = NSRect(x: 4, y: 24, width: 44, height: 14)
        remaining.frame = NSRect(x: w - 48, y: 24, width: 44, height: 14)

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        slider.refusesFirstResponder = true
        slider.frame = NSRect(x: 52, y: 20, width: w - 104, height: 20)
        addSubview(slider)
        show(nil, status: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if showingStatus, let onStatusClick { onStatusClick() } else { super.mouseDown(with: event) }
    }

    /// Updates for an item (nil: nothing playing) or a connection status line.
    func show(_ np: NowPlaying?, status: String?, seekable: Bool = true) {
        showingStatus = status != nil
        if let status {
            label.stringValue = status
            label.textColor = .secondaryLabelColor
        } else if let np {
            label.stringValue = [np.title, np.subtitle].compactMap { $0 }.joined(separator: " — ")
            label.textColor = .labelColor
        } else {
            label.stringValue = "Not Playing"
            label.textColor = .tertiaryLabelColor
        }
        let seekable = seekable && status == nil && (np?.duration ?? 0) > 0
        slider.isHidden = !seekable
        elapsed.isHidden = !seekable
        remaining.isHidden = !seekable
        if let np, seekable, let d = np.duration {
            slider.maxValue = d
            tick(np)
        }
    }

    /// Moves the knob to the extrapolated position (not while the user drags it).
    func tick(_ np: NowPlaying) {
        guard !scrubbing, let d = np.duration, d > 0 else { return }
        let p = np.position()
        slider.doubleValue = p
        setTimes(p, d)
    }

    private func setTimes(_ p: Double, _ d: Double) {
        elapsed.stringValue = NowPlayingStrip.clock(p)
        remaining.stringValue = "-" + NowPlayingStrip.clock(max(0, d - p))
    }

    @objc private func slid() {
        let type = NSApp.currentEvent?.type
        scrubbing = type == .leftMouseDown || type == .leftMouseDragged
        setTimes(slider.doubleValue, slider.maxValue)
        if !scrubbing { onSeek?(slider.doubleValue) }
    }

    /// 0:07 · 12:34 · 1:02:03
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded(.down))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }
}

/// The TV's focused text field, mirrored in a glass capsule: typing here types on the TV
/// (each change goes over as delete/insert at the TV's cursor). Return or Escape hands
/// the keyboard back to the remote; Tab or a click comes back.
final class TextBar: NSView {
    let field = Field()
    private let glass = NSGlassEffectView()
    private let icon = NSImageView()

    var onEdit: ((String) -> Void)? {
        get { field.onEdit }
        set { field.onEdit = newValue }
    }
    var onDone: (() -> Void)? {
        get { field.onDone }
        set { field.onDone = newValue }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        addSubview(glass)
        icon.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 12, y: 0, width: 20, height: bounds.height)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        field.frame = NSRect(x: 38, y: (bounds.height - 20) / 2, width: bounds.width - 52, height: 20)
        field.onFocus = { [weak self] on in
            self?.glass.tintColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.14) : nil
            self?.icon.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        }
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    var isEditing: Bool { field.currentEditor() != nil && window?.firstResponder === field.currentEditor() }

    final class Field: NSTextField {
        var onEdit: ((String) -> Void)?
        var onDone: (() -> Void)?
        var onFocus: ((Bool) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            font = .systemFont(ofSize: 14)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            cell?.sendsActionOnEndEditing = false
            cell?.usesSingleLineMode = true
            cell?.isScrollable = true
            cell?.wraps = false
            target = self
            action = #selector(returned)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?(true) }
            return ok
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocus?(false)
        }

        override func textDidChange(_ notification: Notification) {
            super.textDidChange(notification)
            // An IME composition (marked text) isn't text yet: send it once committed.
            if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            onEdit?(stringValue)
        }

        @objc private func returned() { onDone?() }

        override func cancelOperation(_ sender: Any?) { onDone?() }
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
