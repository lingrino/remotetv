import AppKit
import RemoteCore

/// `tvctl` commands, run on the app's session (see ControlServer). Every reply is text;
/// failures use exit code 1 and say why in one line.
@MainActor
extension AppDelegate {
    static let usage = """
    tvctl — control the Apple TV through RemoteTV

      status                  connection, power, controls, now playing
      np                      now playing (title, position, state)
      press <button>…         click buttons: up down left right select menu home
                              playpause volumeup volumedown siri screensaver …
      hold <button> [s]       hold a button (default 1 s; long-press menus)
      skip <±seconds>         skip playback
      seek <seconds|m:ss>     jump to a position
      mute | captions         toggle mute (needs the AirPlay link) / subtitles
      sleep | wake | power    TV power
      text <string>           replace the focused TV text field's text
      type <string>           type at the cursor
      launch <bundle-id|url>  open an app or a deep link
      apps                    installed apps (bundle id, name)
      upnext                  continue-watching list
      show | hide             the RemoteTV window
      sidebar [on|off|upnext|apps]  the sidebar (now playing, Up Next, apps)
      raw <_i> [k=v…]         any Companion request (debugging)
      snapshot <png> [dark|light] [controls]   window to PNG (debugging)
      direct <command>        talk to the TV over tvctl's own connection (kicks the app's)
      scan | pair <tv>        find Apple TVs / pair (direct)
    """

    func command(_ args: [String], reply: @escaping @MainActor (String, Int32) -> Void) {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        let ok: @MainActor (String) -> Void = { reply($0, 0) }
        let fail: @MainActor (String) -> Void = { reply($0, 1) }

        switch cmd {
        case "help", "-h", "--help":
            return ok(AppDelegate.usage)
        case "reload":   // tvctl pair changed the pairings
            store = CredentialStore()
            if let r = remote, let creds = store.credentials(for: r.device.name) {
                if creds != r.credentials { use(r.device.name, creds) }
            } else if let name = store.last, let creds = store.credentials(for: name) {
                use(name, creds)
            }
            return ok("")
        case "show":
            show()
            return ok("")
        case "hide":
            hide()
            return ok("")
        case "sidebar":
            let a = rest.first
            setSidebar(a.map { $0 != "off" && $0 != "close" } ?? !sidebarOpen, animate: true)
            if a == "apps" { sidebarTab(1) } else if a == "upnext" { sidebarTab(0) }
            return ok("")
        case "snapshot":
            // Debug: window content to PNG (Liquid Glass doesn't render offscreen). Options:
            // dark | light (appearance for this shot), controls (hide the pairing panel).
            guard let path = rest.first else { return fail("usage: snapshot <path.png> [dark|light] [controls]") }
            let saved = window.appearance
            if rest.contains("dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if rest.contains("light") { window.appearance = NSAppearance(named: .aqua) }
            if rest.contains("controls") { view.showsPairing = false }
            snapshot(to: (path as NSString).expandingTildeInPath)
            window.appearance = saved
            return ok(path)
        case "status":
            return ok(statusReport())
        default:
            break
        }

        guard let r = remote else { return fail("not paired: run `tvctl pair <tv>` or pair in the app") }
        if !window.isVisible || NSApp.isHidden { armIdle() }   // a hidden app's session still times out
        ready(r) { [weak self] connected in
            guard let self else { return }
            guard connected else { return fail("\(r.device.name): \(AppDelegate.describe(r.status))") }
            self.run(cmd, rest, on: r, ok: ok, fail: fail)
        }
    }

    private func run(_ cmd: String, _ rest: [String], on r: Remote, ok: @escaping @MainActor (String) -> Void,
                     fail: @escaping @MainActor (String) -> Void) {
        switch cmd {
        case "np":
            guard let np = r.nowPlaying else { return ok("nothing playing") }
            ok(AppDelegate.describe(np))
        case "press":
            let buttons = rest.compactMap(Button.named)
            guard !buttons.isEmpty, buttons.count == rest.count else { return fail("unknown button in: \(rest.joined(separator: " "))") }
            for b in buttons { r.press(b) }
            ok("")
        case "hold":
            guard let b = rest.first.flatMap(Button.named) else { return fail("usage: hold <button> [seconds]") }
            let secs = rest.dropFirst().first.flatMap(Double.init) ?? 1
            r.button(b, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + min(10, max(0.05, secs))) {
                MainActor.assumeIsolated {
                    r.button(b, down: false)
                    ok("")
                }
            }
        case "skip":
            guard let s = rest.first.flatMap(Double.init) else { return fail("usage: skip <±seconds>") }
            r.skip(s)
            ok("")
        case "seek":
            guard let s = rest.first.flatMap(AppDelegate.seconds) else { return fail("usage: seek <seconds|m:ss|h:mm:ss>") }
            guard r.nowPlaying != nil else { return fail("nothing playing") }
            r.seek(to: s)
            ok("")
        case "mute":
            guard r.muteAvailable else { return fail("mute needs the AirPlay link, which isn't up") }
            r.toggleMute()
            ok("")
        case "captions":
            r.toggleCaptions()
            ok("")
        case "sleep": r.sleep(); ok("")
        case "wake": r.wake(); ok("")
        case "power": r.togglePower(); ok("")
        case "text", "type":
            guard r.textSession != nil else { return fail("no text field is focused on the TV") }
            let t = rest.joined(separator: " ")
            if cmd == "text" { r.setText(t) } else { r.editText(delete: 0, insert: t) }
            ok("")
        case "launch":
            guard let target = rest.first else { return fail("usage: launch <bundle-id|url>") }
            if target.contains("://") { r.open(url: target) } else { r.launch(bundleID: target) }
            ok("")
        case "apps":
            r.fetchApps(icons: false) { apps in
                ok(apps.map { "\($0.bundleID)\t\($0.name)" }.joined(separator: "\n"))
            }
        case "upnext":
            r.fetchUpNext { items in
                guard let items else { return fail("the Apple TV couldn't list Up Next right now") }
                ok(items.map { i in
                    [i.title, i.subtitle ?? "", i.service ?? "", i.reason ?? "", i.actionURL ?? ""].joined(separator: "\t")
                }.joined(separator: "\n"))
            }
        case "raw":
            guard let id = rest.first else { return fail("usage: raw <_i> [key=value…]") }
            let content: [String: OPACK.Value]
            switch OPACK.arguments(rest.dropFirst()) {
            case .success(let c): content = c
            case .failure(let e): return fail(e.description)
            }
            r.raw(id, content) { value, error in
                if let error { return fail(error) }
                ok(value.map { "\($0)" }?.replacing("RemoteCore.OPACK.Value.", with: "") ?? "")
            }
        default:
            fail("unknown command \(cmd) (tvctl help)")
        }
    }

    /// Waits (≤5 s) for the session, starting one if needed.
    private func ready(_ r: Remote, _ done: @escaping @MainActor (Bool) -> Void) {
        if r.status == .connected { return done(true) }
        switch r.status {
        case .failed, .idle: r.reconnect()
        default: break
        }
        let start = Date()
        func poll() {
            if r.status == .connected { return done(true) }
            if r.status == .unpaired || Date().timeIntervalSince(start) > 5 { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
        }
        poll()
    }

    private func statusReport() -> String {
        guard let r = remote else { return "not paired" }
        var lines = ["\(r.device.name): \(AppDelegate.describe(r.status))"]
        lines.append("power: \(r.power)")
        lines.append("airplay link: \(r.muteAvailable ? "up" : "down")")
        lines.append("controls: \(r.controlsKnown ? String(r.controls.rawValue, radix: 16) : "unknown")")
        lines.append("text field: \(r.textSession.map { "focused (\"\($0.text)\")" } ?? "none")")
        lines.append("now playing: \(r.nowPlaying.map(AppDelegate.describe) ?? "nothing")")
        let others = devices.map(\.name).filter { $0 != r.device.name }
        if !others.isEmpty { lines.append("other Apple TVs: \(others.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ s: Remote.Status) -> String {
        switch s {
        case .idle: "idle"
        case .connecting: "connecting"
        case .waitingForPIN: "waiting for the PIN"
        case .pairing: "pairing"
        case .connected: "connected"
        case .failed(let e): e.description
        case .unpaired: "the TV forgot this pairing; pair again"
        }
    }

    static func describe(_ np: NowPlaying) -> String {
        let title = [np.title, np.subtitle].compactMap { $0 }.joined(separator: " — ")
        let pos = NowPlayingStrip.clock(np.position())
        let len = np.duration.map { " / " + NowPlayingStrip.clock($0) } ?? " (live)"
        let state = np.isPlaying ? "playing" : (np.state == 2 ? "paused" : "state \(np.state)")
        let subs = np.hasCaptions ? (np.captionsEnabled ? ", subtitles on" : ", subtitles off") : ""
        return "\(title.isEmpty ? "?" : title)  \(pos)\(len)  \(state)\(subs)"
    }

    /// "754", "12:34", "1:02:03" → seconds.
    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: - Installing tvctl

    /// Puts `tvctl` on the PATH: a symlink in ~/.local/bin (on the owner's PATH, owned by
    /// them: no admin prompt) to the copy inside this app bundle. Leaves anything that
    /// isn't a symlink into a RemoteTV.app alone. Runs after launch; costs a few stats.
    func installCLI() {
        let fm = FileManager.default
        let bin = fm.homeDirectoryForCurrentUser.appending(path: ".local/bin").path
        let target = Bundle.main.bundleURL.appending(path: "Contents/Helpers/tvctl").path
        guard fm.fileExists(atPath: target) else { return }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bin, isDirectory: &isDir), isDir.boolValue else { return }
        let link = bin + "/tvctl"
        if let current = try? fm.destinationOfSymbolicLink(atPath: link) {
            if current == target { return }
            guard current.contains("RemoteTV.app/") else { return }   // someone else's tvctl
            try? fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            return   // a real file: not ours to replace
        }
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
    }
}
