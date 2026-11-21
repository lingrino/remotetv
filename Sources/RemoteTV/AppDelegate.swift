import AppKit
import Network
import RemoteCore
import os

/// Wiring and state: one window, one `Remote` (the selected Apple TV), the pairing store,
/// Bonjour browsing (for the TV menu and pairing), keyboard and media keys.
///
/// Startup order matters for "usable the moment it appears": the window is built and
/// shown first, the connection to the last-used TV starts in the same run-loop turn
/// (no Bonjour browse needed: the endpoint is the service name), and everything else
/// (browsing, the media-key tap) waits until after the first frame.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    lazy var view = RemoteView()
    var store = CredentialStore()
    var remote: Remote?
    private var pairer: Remote?
    var devices: [Device] = []
    private var browser: Browser?
    private let mediaKeys = MediaKeys()
    private var heldKeys: [UInt16: Button] = [:]
    private var control: ControlServer?
    private var retryCount = 0
    private var retryItem: DispatchWorkItem?

    static let log = Logger(subsystem: "com.lingrino.remotetv", category: "app")

    /// Runs in `main` before AppKit starts (NSApplication.shared alone takes ~50 ms):
    /// the TCP connection and mDNS lookup proceed while AppKit initializes, and
    /// pair-verify runs in the first run-loop turns.
    override init() {
        super.init()
        if let name = store.last, let creds = store.credentials(for: name) {
            remote = makeRemote(Device(name: name), creds)
            remote?.connect()
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Launch.mark("didFinishLaunching")
        buildMenu()
        buildWindow()
        if let r = remote {
            showRemote(r)
        } else {
            startPairing()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        Launch.mark("window")
        DispatchQueue.main.async { Launch.mark("nextTurn") }
        DispatchQueue.main.async { [self] in
            control = ControlServer { [weak self] args, reply in
                guard let self else { return reply("not running", 1) }
                self.command(args, reply: reply)
            }
            control?.start()
            installCLI()
            browse()
            mediaKeys.handler = { [weak self] key, down, rep in self?.mediaKey(key, down: down, repeat: rep) ?? false }
            if NSApp.isActive { mediaKeys.enable() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        watchNetwork()
    }

    // Closing the window hides it and the app keeps running, connected: launching it
    // again (Fred, Dock, Spotlight) is a reopen, which shows the window in a few ms with
    // the session already up. ⌘Q quits. After `idleDisconnect` hidden, the connection is
    // dropped (it's re-made in ~30 ms on the next show).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit: say goodbye to the TV first (`_sessionStop`, ≤0.3 s) like Apple's remote.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let r = remote, r.status == .connected else { return .terminateNow }
        r.goodbye { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show()
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private static let idleDisconnect: Double = 600
    private var idleItem: DispatchWorkItem?

    func show() {
        idleItem?.cancel()
        if !window.isVisible { Launch.reopened() }
        window.makeKeyAndOrderFront(nil)
        if !view.showsPairing { window.makeFirstResponder(view) }
        NSApp.activate()
        reconnectIfNeeded()
        remote?.probe()
        remote?.refreshNowPlaying()
        updateTicker()
    }

    func hide() {
        releaseAll()
        window.orderOut(nil)
        updateTicker()
        NSApp.hide(nil)
        idleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.window.isVisible else { return }
                self.retryItem?.cancel()
                self.remote?.goodbye()
                self.pairer?.disconnect()
            }
        }
        idleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.idleDisconnect, execute: item)
    }

    func applicationDidBecomeActive(_ note: Notification) {
        if window != nil && !window.isVisible { show() }
        let tap = mediaKeys.enable()
        AppDelegate.log.info("active; accessibility \(MediaKeys.trusted ? "granted" : "not granted", privacy: .public), media-key tap \(tap ? "on" : "off", privacy: .public)")
        reconnectIfNeeded()
        remote?.probe()
    }

    func applicationDidResignActive(_ note: Notification) {
        mediaKeys.disable()
        releaseAll()
    }

    func windowDidResignKey(_ notification: Notification) { releaseAll() }

    /// Mac sleep: close the session cleanly and don't retry while asleep; wake: a fresh
    /// connection (the old socket may be half-open after the network went away).
    @objc private func willSleep() {
        retryItem?.cancel()
        sleeping = true
        remote?.goodbye()
    }

    @objc private func didWake() {
        sleeping = false
        guard window?.isVisible == true else { return }
        remote?.reconnect()
    }

    private var sleeping = false
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?

    /// Network changes (Wi-Fi to Ethernet, another network, VPN up/down) leave the TCP
    /// connections on a dead path; keepalive would notice only after ~20 s. Reconnect
    /// right away instead, and as soon as a network comes back after none.
    private func watchNetwork() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let sig = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
                + " " + path.gateways.map { "\($0)" }.joined(separator: ",")
            let ok = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(sig, satisfied: ok) } }
        }
        m.start(queue: .global(qos: .utility))
        pathMonitor = m
    }

    private func networkChanged(_ sig: String, satisfied: Bool) {
        defer { pathSignature = sig }
        guard let old = pathSignature, old != sig, satisfied, !sleeping else { return }
        AppDelegate.log.info("network changed; reconnecting")
        guard window?.isVisible == true || remote?.status == .connected else { return }
        retryCount = 0
        remote?.reconnect()
    }

    // MARK: - URLs

    /// `remotetv://` URLs, for scripting (Fred, Shortcuts, `open`) and live testing:
    ///   remotetv://show · remotetv://hide
    ///   remotetv://press/<button>[/<button>…]   (up down left right select menu home playpause volumeup volumedown)
    ///   remotetv://skip/<seconds>               (negative = back)
    ///   remotetv://sleep · remotetv://wake
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "remotetv" {
            let parts = [url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }
            switch parts.first {
            case "show": show()
            case "hide": hide()
            case "press":
                for name in parts.dropFirst() {
                    if let b = Button.named(name) { remote?.press(b) }
                }
            case "skip": if let s = parts.dropFirst().first.flatMap(Double.init) { remote?.skip(s) }
            case "snapshot":
                // Debug: PNG of the window content (glass doesn't render offscreen).
                let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if q.contains(where: { $0.name == "controls" }) { view.showsPairing = false }
                if let a = q.first(where: { $0.name == "appearance" })?.value {
                    window.appearance = a == "system" ? nil : NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
                }
                if let path { snapshot(to: path) }
            case "pairing": startPairing()
            case "sleep": remote?.sleep()
            case "wake": remote?.wake()
            default: AppDelegate.log.notice("unknown URL \(url.absoluteString, privacy: .public)")
            }
        }
    }

    func snapshot(to path: String) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: RemoteView.height),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "RemoteTV"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        window.animationBehavior = .none
        // Restore the position (keeping the top edge) but never a stale size from an
        // older layout.
        let restored = window.setFrameUsingName("Remote")
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.frame.size)).size
        var f = window.frame
        if restored { f.origin.y += f.height - size.height }
        f.size = size
        window.setFrame(f, display: false)
        if !restored { window.center() }
        window.setFrameAutosaveName("Remote")

        view.onKey = { [weak self] e, down in self?.key(e, down: down) ?? false }
        view.title.target = self
        view.title.action = #selector(showDeviceMenu)
        view.power.onClick = { [weak self] in self?.remote?.togglePower() }
        view.captions.onClick = { [weak self] in
            if self?.remote?.nowPlaying?.hasCaptions == true { self?.remote?.toggleCaptions() }
        }
        view.strip.onStatusClick = { [weak self] in
            guard self?.remote?.status == .failed(ProtocolError.localNetworkDenied.description) else { return }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
        }
        view.strip.onSeek = { [weak self] t in self?.remote?.seek(to: t) }
        view.text.onEdit = { [weak self] t in
            guard let self else { return }
            let (delete, insert) = RTI.diff(from: self.sentText, to: t)
            self.sentText = t
            self.remote?.editText(delete: delete, insert: insert)
        }
        view.text.onDone = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.view)
        }
        view.pad.onButton = { [weak self] b, down in self?.remote?.button(b, down: down) }
        view.pad.onTouch = { [weak self] x, y, phase in self?.remote?.touch(x: x, y: y, phase: phase) }
        view.skipBack.onPress = { [weak self] down in if down { self?.remote?.skip(-10) } }
        view.skipForward.onPress = { [weak self] down in if down { self?.remote?.skip(10) } }
        view.playPause.onPress = { [weak self] down in self?.remote?.button(.playPause, down: down) }
        view.back.onPress = { [weak self] down in self?.remote?.button(.menu, down: down) }
        view.home.onPress = { [weak self] down in self?.remote?.button(.home, down: down) }
        view.volume.onPress = { [weak self] part, down in
            switch part {
            case .down: self?.remote?.button(.volumeDown, down: down)
            case .up: self?.remote?.button(.volumeUp, down: down)
            case .mute: if !down { self?.remote?.toggleMute() }
            }
        }
        view.pairing.onPick = { [weak self] name in self?.pair(name) }
        view.pairing.pin.target = self
        view.pairing.pin.action = #selector(pinEntered)
        view.pairing.cancel.target = self
        view.pairing.cancel.action = #selector(cancelPairing)
        NotificationCenter.default.addObserver(self, selector: #selector(pinChanged),
                                               name: NSControl.textDidChangeNotification, object: view.pairing.pin)
    }

    // MARK: - Remote

    /// Makes `name` the controlled Apple TV and connects.
    func use(_ name: String, _ creds: Credentials) {
        remote?.disconnect()
        let r = makeRemote(device(named: name), creds)
        remote = r
        showRemote(r)
        r.connect()
    }

    private func makeRemote(_ device: Device, _ creds: Credentials) -> Remote {
        retryItem?.cancel()
        retryCount = 0
        let r = Remote(device: device, credentials: creds)
        adopt(r)
        return r
    }

    /// Routes a session's callbacks here (only while it is the current remote).
    private func adopt(_ r: Remote) {
        r.onStatus = { [weak self, weak r] s in
            guard let self, let r, r === self.remote else { return }
            self.statusChanged(s)
        }
        r.onPower = { [weak self, weak r] _ in
            guard let self, let r, r === self.remote else { return }
            self.updateHeader()
        }
        r.onNowPlaying = { [weak self, weak r] _ in
            guard let self, let r, r === self.remote else { return }
            self.updateHeader()
        }
        r.onMediaReady = { [weak self, weak r] _ in
            guard let self, let r, r === self.remote else { return }
            self.updateHeader()
        }
        r.onControls = { [weak self, weak r] _ in
            guard let self, let r, r === self.remote else { return }
            self.updateHeader()
        }
        r.onTextSession = { [weak self, weak r] s in
            guard let self, let r, r === self.remote else { return }
            self.textSessionChanged(s)
        }
        r.onTiming = { what, d in
            if what == "session" { Launch.mark("connected") }
            AppDelegate.log.debug("\(what, privacy: .public): \(d, privacy: .public)")
        }
    }

    private func showRemote(_ r: Remote) {
        view.showsPairing = false
        window.makeFirstResponder(view)
        updateHeader()
    }

    private func device(named name: String) -> Device {
        devices.first { $0.name == name } ?? Device(name: name)
    }

    private func statusChanged(_ s: Remote.Status) {
        guard window != nil else { return }   // still launching: the window shows the state when it's built
        updateHeader()
        switch s {
        case .connected:
            retryCount = 0
            if let name = remote?.device.name, store.last != name { try? store.touch(name) }
        case .failed(let e):
            scheduleRetry()
            if e.hasPrefix("couldn't find") || e == ProtocolError.timeout.description { followRename() }
        default:
            break
        }
    }

    // MARK: - Renamed TVs

    private var renameProbe: Remote?
    private var lastRenameProbe = Date.distantPast

    /// Pairings are stored by the TV's name, which is also how it's found (Bonjour). If
    /// the TV was renamed, the old name is gone; any Apple TV on the network whose name
    /// isn't paired is tried with the current credentials: pair-verify only succeeds on
    /// the TV that holds them (it proves its identity), and then the pairing moves over.
    private func followRename() {
        guard renameProbe == nil, Date().timeIntervalSince(lastRenameProbe) > 30,
              let r = remote, let creds = r.credentials else { return }
        let paired = Set(store.entries.map(\.name))
        guard let candidate = devices.first(where: { !paired.contains($0.name) }) else { return }
        lastRenameProbe = Date()
        let old = r.device.name
        let p = Remote(device: candidate, credentials: creds)
        renameProbe = p
        p.onStatus = { [weak self, weak p] s in
            guard let self, let p, p === self.renameProbe else { return }
            switch s {
            case .connected:
                AppDelegate.log.notice("\(old, privacy: .public) is now \(candidate.name, privacy: .public)")
                self.renameProbe = nil
                try? self.store.remove(old)
                try? self.store.save(candidate.name, creds)
                self.remote?.disconnect()
                self.remote = p
                self.adopt(p)
                self.showRemote(p)
                self.statusChanged(s)
            case .failed, .unpaired:
                self.renameProbe = nil
                p.disconnect()
            default:
                break
            }
        }
        p.connect()
    }

    /// Reconnects after a failure while the app is in use: quickly at first (a TV that
    /// just woke up), then backing off to every 8 s.
    private func scheduleRetry() {
        retryItem?.cancel()
        guard window?.isVisible == true, remote?.isPaired == true else { return }
        let delays: [Double] = [0.3, 1, 2, 4, 8]
        let delay = delays[min(retryCount, delays.count - 1)]
        retryCount += 1
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.remote?.connect() }
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reconnectIfNeeded(now: Bool = false) {
        guard let r = remote, r.isPaired else { return }
        switch r.status {
        case .failed, .idle:
            retryItem?.cancel()
            retryCount = 0
            r.connect()
        default:
            break
        }
    }

    private func updateHeader() {
        guard window != nil else { return }
        guard let r = remote, !view.showsPairing else {
            view.title.title = "RemoteTV"
            return
        }
        view.title.title = r.device.name
        let status: String? = switch r.status {
        case .connected, .idle: nil
        case .connecting, .pairing: "Connecting…"
        case .unpaired: "\(r.device.name) forgot this Mac. Pair again from the menu above."
        case .failed(let e) where e == ProtocolError.localNetworkDenied.description:
            "Local Network access is off. Click to allow it."
        case .waitingForPIN: "Pairing…"
        case .failed(let e): e.prefix(1).uppercased() + e.dropFirst()
        }
        view.strip.show(status == nil ? r.nowPlaying : nil, status: status, seekable: r.canSeek)
        view.setPower(asleep: r.power == .asleep)
        let known = r.controlsKnown && r.status == .connected
        let volume = !known || r.controls.contains(.volume)
        view.setAvailability(skip: !known || r.controls.contains(.skipForward) || r.controls.contains(.skipBackward),
                             volume: volume)
        view.volume.muteAvailable = r.muteAvailable && volume
        let np = r.nowPlaying
        view.setCaptions(available: np?.hasCaptions ?? false, on: np?.captionsEnabled ?? false)
        updateTicker()
    }

    // MARK: - Now playing and text

    private var ticker: Timer?

    /// Moves the scrubber while something plays and the window is visible (2 Hz; the
    /// position is extrapolated locally, nothing is sent).
    private func updateTicker() {
        let run = window?.isVisible == true && remote?.nowPlaying?.isPlaying == true && remote?.status == .connected
        if run && ticker == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let np = self.remote?.nowPlaying else { return }
                    self.view.strip.tick(np)
                }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !run {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// What the TV field holds as far as we know (its reported text plus our edits).
    private var sentText = ""

    private func textSessionChanged(_ s: TextSession?) {
        guard window != nil else { return }
        if let s {
            sentText = s.text
            view.text.field.stringValue = s.text
            view.showText(true)
            window.makeFirstResponder(view.text.field)
            view.text.field.currentEditor()?.selectedRange = NSRange(location: (s.text as NSString).length, length: 0)
        } else {
            let editing = view.text.isEditing
            view.showText(false)
            if editing { window.makeFirstResponder(view) }
        }
    }

    // MARK: - Device menu and browsing

    private func browse() {
        guard browser == nil else { return }
        let b = Browser { [weak self] found in
            guard let self else { return }
            self.devices = found
            if self.view.showsPairing && self.pairer == nil { self.showDeviceList() }
        }
        browser = b
        b.start()
    }

    @objc private func showDeviceMenu() {
        let menu = NSMenu()
        let current = remote?.device.name
        var names = store.entries.map(\.name)
        for d in devices where !names.contains(d.name) { names.append(d.name) }
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(menuPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == current ? .on : .off
            let lost = name == current && remote?.status == .unpaired
            if store.credentials(for: name) == nil || lost { item.title = "\(name) — Pair Again…" }
            menu.addItem(item)
        }
        if names.isEmpty {
            let item = NSMenuItem(title: "Looking for Apple TVs…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pairItem = NSMenuItem(title: "Pair Another Apple TV…", action: #selector(startPairingAction), keyEquivalent: "")
        pairItem.target = self
        menu.addItem(pairItem)
        if let current, store.credentials(for: current) != nil {
            let forget = NSMenuItem(title: "Forget “\(current)”", action: #selector(forgetCurrent), keyEquivalent: "")
            forget.target = self
            menu.addItem(forget)
        }
        let b = view.title
        menu.popUp(positioning: nil, at: NSPoint(x: b.bounds.midX - 60, y: b.bounds.maxY + 4), in: b)
    }

    @objc private func menuPick(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        if name == remote?.device.name, remote?.status == .unpaired { return pair(name) }
        if let creds = store.credentials(for: name) { use(name, creds) } else { pair(name) }
    }

    @objc private func forgetCurrent() {
        guard let name = remote?.device.name else { return }
        try? store.remove(name)
        remote?.disconnect()
        remote = nil
        if let next = store.last, let creds = store.credentials(for: next) { use(next, creds) } else { startPairing() }
    }

    // MARK: - Pairing

    @objc private func startPairingAction() { startPairing() }

    private func startPairing() {
        pairer?.disconnect()
        pairer = nil
        view.showsPairing = true
        updateHeader()
        showDeviceList()
        browse()
    }

    private func showDeviceList() {
        view.pairing.showDevices(devices.map(\.name), paired: Set(store.entries.map(\.name)))
    }

    private func pair(_ name: String) {
        view.showsPairing = true
        updateHeader()
        let p = Remote(device: device(named: name), credentials: nil)
        p.onStatus = { [weak self, weak p] s in
            guard let self, let p, p === self.pairer else { return }
            self.pairingStatus(p, s)
        }
        p.onPaired = { [weak self] creds in
            guard let self else { return }
            do { try self.store.save(name, creds) } catch {
                AppDelegate.log.error("saving pairing: \(error.localizedDescription, privacy: .public)")
            }
        }
        pairer = p
        view.pairing.showWorking("Connecting to “\(name)”…")
        view.pairing.heading.stringValue = "Pairing"
        p.pair()
    }

    private func pairingStatus(_ p: Remote, _ s: Remote.Status) {
        // Paired: from here on this session is the remote (connected, or failing to
        // connect, which the normal retry handles).
        if p.credentials != nil, s == .connected || s.isFailure {
            pairer = nil
            remote?.disconnect()
            remote = p
            adopt(p)
            showRemote(p)
            statusChanged(s)
            return
        }
        switch s {
        case .waitingForPIN:
            view.pairing.showPIN(for: p.device.name, error: nil)
        case .pairing:
            view.pairing.showWorking("Pairing…")
        case .failed(let e):
            view.pairing.showPIN(for: p.device.name, error: e.prefix(1).uppercased() + e.dropFirst())
            view.pairing.pin.isEnabled = false
            view.pairing.detail.stringValue += " Choose the Apple TV to try again."
            pairer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.pairer == nil, self.view.showsPairing else { return }
                self.showDeviceList()
            }
        default:
            break
        }
    }

    @objc private func pinChanged() {
        let digits = view.pairing.pin.stringValue.filter(\.isNumber)
        if digits != view.pairing.pin.stringValue { view.pairing.pin.stringValue = String(digits.prefix(4)) }
        if digits.count == 4 { pinEntered() }
    }

    @objc private func pinEntered() {
        let digits = view.pairing.pin.stringValue.filter(\.isNumber)
        guard digits.count == 4, let p = pairer, p.status == .waitingForPIN else { return }
        p.submitPIN(digits)
    }

    @objc private func cancelPairing() {
        pairer?.disconnect()
        pairer = nil
        if remote != nil {
            view.showsPairing = false
            window.makeFirstResponder(view)
            updateHeader()
        } else {
            showDeviceList()
        }
    }

    // MARK: - Keyboard

    /// Remote keys while the window is key. Arrows/Return/Delete/Space/T are held like the
    /// Siri Remote's buttons (down on key down, up on key up); [ ] skip; - = volume.
    private func key(_ e: NSEvent, down: Bool) -> Bool {
        guard let r = remote, !view.showsPairing else { return false }
        if e.modifierFlags.contains(.command) { return false }
        let code = e.keyCode
        if code == 48, down, !view.text.isHidden {   // Tab: back into the TV's text field
            window.makeFirstResponder(view.text.field)
            return true
        }
        let held: Button? = switch code {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .select           // Return, keypad Enter
        case 51, 53, 117: .menu        // Delete, Escape, forward delete
        case 49: .playPause            // Space
        case 17, 4: .home              // T, H
        default: nil
        }
        if let b = held {
            if down {
                if !e.isARepeat && heldKeys[code] == nil {
                    heldKeys[code] = b
                    r.button(b, down: true)
                }
            } else if let b = heldKeys.removeValue(forKey: code) {
                r.button(b, down: false)
            }
            return true
        }
        guard down else { return code == 33 || code == 30 || code == 27 || code == 24 }
        switch code {
        case 33: if !e.isARepeat { r.skip(-10) }   // [
        case 30: if !e.isARepeat { r.skip(10) }    // ]
        case 27: r.press(.volumeDown)               // -
        case 24: r.press(.volumeUp)                 // =
        default: return false
        }
        return true
    }

    /// Lets go of every held key and click (focus moved away mid-press).
    private func releaseAll() {
        for (_, b) in heldKeys { remote?.button(b, down: false) }
        heldKeys.removeAll()
        view.pad.cancel()
    }

    /// Volume/play keys while RemoteTV is active. Returns false for keys it leaves to
    /// macOS (mute).
    private func mediaKey(_ key: MediaKeys.Key, down: Bool, repeat rep: Bool) -> Bool {
        guard let r = remote else { return false }
        switch key {
        case .volumeUp: if down { r.press(.volumeUp) }
        case .volumeDown: if down { r.press(.volumeDown) }
        case .playPause: if down && !rep { r.press(.playPause) }
        case .next, .fast: if down && !rep { r.skip(10) }
        case .previous, .rewind: if down && !rep { r.skip(-10) }
        case .mute: return false
        }
        return true
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide RemoteTV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit RemoteTV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }
}

/// Launch-to-milestone timing, from the process start time (so it includes dyld and
/// AppKit startup), logged once per milestone.
enum Launch {
    private static let start: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }()
    @MainActor private static var seen: Set<String> = []

    /// Reopen → window on screen, logged on the next run-loop turn (after the commit).
    @MainActor static func reopened() {
        let t0 = Date()
        DispatchQueue.main.async {
            AppDelegate.log.notice("reopen→shown: \((Date().timeIntervalSince(t0) * 1000), format: .fixed(precision: 1), privacy: .public) ms")
        }
    }

    @MainActor static func mark(_ what: String) {
        guard seen.insert(what).inserted else { return }
        let ms = (Date().timeIntervalSince1970 - start) * 1000
        AppDelegate.log.notice("launch→\(what, privacy: .public): \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }
}
