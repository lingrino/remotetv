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
    var pairer: Remote?
    var devices: [Device] = []
    var browser: Browser?
    let mediaKeys = MediaKeys()
    var heldKeys: [UInt16: Button] = [:]
    var control: ControlServer?
    let root = Flipped()

    // MARK: Sidebar state (see Sidebar.swift)
    var sidebar: Sidebar?
    var sidebarOpen = false
    var tvApps: [TVApp]?
    var loadingApps = false
    var upNext: [UpNextItem]?

    func sidebarTab(_ t: Int) {
        sidebar?.tab = t
        UserDefaults.standard.set(t, forKey: "sidebarTab")
    }
    var retryCount = 0
    var retryItem: DispatchWorkItem?

    static let log = Logger(subsystem: "com.lingrino.remotetv", category: "app")

    // State for the extensions (AppDelegate+*.swift).
    var renameProbe: Remote?
    var lastRenameProbe = Date.distantPast
    /// Candidates already tried since the TV went missing (each gets one try per streak).
    var renameTried: Set<String> = []

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
        if UserDefaults.standard.bool(forKey: "sidebarOpen") {
            DispatchQueue.main.async { [self] in setSidebar(true, animate: false) }
        }
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

    static let idleDisconnect: Double = 600
    var idleItem: DispatchWorkItem?

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
        browse()
        if sidebarOpen { remote?.wantsArtwork = true; loadSidebar() }
    }

    func hide() {
        window.orderOut(nil)
        NSApp.hide(nil)
        wentAway()
    }

    /// The window is out of sight (closed, ⌘H, hidden by tvctl): stop everything that
    /// only serves what's on screen, and drop the connection after `idleDisconnect`.
    func wentAway() {
        releaseAll()
        updateTicker()
        remote?.wantsArtwork = false
        browser?.stop()
        browser = nil
        armIdle()
    }

    /// (Re)starts the hidden-window countdown: also after a tvctl command reconnected
    /// while hidden, so that session ends too.
    func armIdle() {
        idleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.window.isVisible || NSApp.isHidden else { return }
                self.retryItem?.cancel()
                self.remote?.goodbye()
                self.pairer?.disconnect()
            }
        }
        idleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.idleDisconnect, execute: item)
    }

    func applicationDidHide(_ note: Notification) { wentAway() }

    func applicationDidUnhide(_ note: Notification) {
        if window?.isVisible == true { show() }
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
    @objc func willSleep() {
        retryItem?.cancel()
        sleeping = true
        remote?.goodbye()
    }

    @objc func didWake() {
        sleeping = false
        guard window?.isVisible == true else { return }
        remote?.reconnect()
    }

    var sleeping = false
    var pathMonitor: NWPathMonitor?
    var pathSignature: String?

    /// Network changes (Wi-Fi to Ethernet, another network, VPN up/down) leave the TCP
    /// connections on a dead path; keepalive would notice only after ~20 s. Reconnect
    /// right away instead, and as soon as a network comes back after none.
    func watchNetwork() {
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

    func networkChanged(_ sig: String, satisfied: Bool) {
        defer { pathSignature = sig }
        guard let old = pathSignature, old != sig, satisfied, !sleeping else { return }
        guard window?.isVisible == true || remote?.status == .connected else { return }
        // A probe, not a reconnect: a VPN or a second interface coming up leaves the LAN
        // path working; if it doesn't, the unanswered probe drops the session in 3 s.
        AppDelegate.log.info("network changed; checking the session")
        retryCount = 0
        remote?.probe(force: true)
    }

    // MARK: - URLs

    /// `remotetv://show`, `remotetv://hide`, `remotetv://sidebar`. Any app or web page can
    /// open a URL, so the scheme only does harmless window things; everything that acts on
    /// the TV or the disk goes through tvctl (the owner-only control socket).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard window != nil else { return }   // cold launch: the window is about to show anyway
        for url in urls where url.scheme == "remotetv" {
            switch url.host() {
            case "show": show()
            case "hide": hide()
            case "sidebar": toggleSidebar()
            default: AppDelegate.log.notice("unknown URL \(url.absoluteString, privacy: .private)")
            }
        }
    }

    func snapshot(to path: String) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Window

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: RemoteView.height),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "RemoteTV"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        root.frame = view.frame
        root.addSubview(view)
        window.contentView = root
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
        // Keys held on the TV must be let go when the remote stops getting key events:
        // focus moved into the text field, or ⌘ went down (AppKit sends no key-up for a
        // key released while ⌘ is held).
        view.onResign = { [weak self] in self?.releaseAll() }
        view.onFlags = { [weak self] e in if e.modifierFlags.contains(.command) { self?.releaseAll() } }
        view.title.target = self
        view.title.action = #selector(showDeviceMenu)
        view.sidebarButton.target = self
        view.sidebarButton.action = #selector(toggleSidebar)
        view.power.onClick = { [weak self] in self?.remote?.togglePower() }
        view.captions.onClick = { [weak self] in
            if self?.remote?.nowPlaying?.hasCaptions == true { self?.remote?.toggleCaptions() }
        }
        view.strip.onStatusClick = { [weak self] in
            guard self?.remote?.status == .failed(.localNetworkDenied) else { return }
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
        if remote?.device.name != name {   // another TV: its apps and Up Next aren't these
            tvApps = nil
            upNext = nil
            sidebar?.setApps(nil)
            sidebar?.setUpNext(nil)
        }
        let r = makeRemote(device(named: name), creds)
        remote = r
        showRemote(r)
        r.connect()
    }

    func makeRemote(_ device: Device, _ creds: Credentials) -> Remote {
        retryItem?.cancel()
        retryCount = 0
        let r = Remote(device: device, credentials: creds)
        adopt(r)
        return r
    }

    /// Routes a session's callbacks here (only while it is the current remote).
    func adopt(_ r: Remote) {
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

    func showRemote(_ r: Remote) {
        view.showsPairing = false
        window.makeFirstResponder(view)
        updateHeader()
    }

    func device(named name: String) -> Device {
        devices.first { $0.name == name } ?? Device(name: name)
    }

    func statusChanged(_ s: Remote.Status) {
        guard window != nil else { return }   // still launching: the window shows the state when it's built
        updateHeader()
        switch s {
        case .connected:
            retryCount = 0
            renameTried.removeAll()
            if let name = remote?.device.name, store.last != name { try? store.touch(name) }
        case .failed(let e):
            scheduleRetry()
            if e == .notFound || e == .timeout { followRename() }
        default:
            break
        }
    }

    // MARK: - Now playing and text

    var ticker: Timer?

    /// Moves the scrubber while something plays and the window is visible (2 Hz; the
    /// position is extrapolated locally, nothing is sent).
    func updateTicker() {
        let run = window?.isVisible == true && !NSApp.isHidden && remote?.nowPlaying?.isPlaying == true && remote?.status == .connected
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
    var sentText = ""

    func textSessionChanged(_ s: TextSession?) {
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

    // MARK: - Menu

    func buildMenu() {
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
        winMenu.addItem(.separator())
        let sb = winMenu.addItem(withTitle: "Show Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        sb.keyEquivalentModifierMask = [.control, .command]
        sb.target = self
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
