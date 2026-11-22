import Foundation
import RemoteCore

// tvctl: the RemoteTV command line. Installed with the app (a symlink in ~/.local/bin).
// `tvctl help` is the manual; its words are in RemoteCore (TVCommand+Help).
//
// The TV keeps one connection per pairing, so one process talks to it at a time:
//   - RemoteTV is running: commands go to it over its control socket and use its session
//     (no handshake, nothing to fight over).
//   - It isn't: tvctl connects itself, runs the one command, waits until the TV has it,
//     says goodbye and exits (`oneShot`). The app is not started. The commands are the
//     same code either way (RemoteCore's TVCommand).
// What doesn't act on the TV is done here (the pairings: tvs, scan, pair, use, forget) or
// by the app (its window: show, hide, sidebar; these start it).
//
// `tvctl debug …`, `--direct` and `-v` are for working on the protocol code (`tvctl help debug`).

typealias Invocation = TVCommand.Invocation
typealias Result = TVCommand.Result

// MARK: - Output

/// Prints a command's reply and exits with its status. Results go to stdout, failures to
/// stderr; with --json the one object always goes to stdout.
func finish(_ text: String, _ code: Int32, json: Bool) -> Never {
    var t = text
    if !t.isEmpty && !t.hasSuffix("\n") { t += "\n" }
    (code == 0 || json ? FileHandle.standardOutput : FileHandle.standardError).write(Data(t.utf8))
    exit(code)
}

func finish(_ result: Result, json: Bool) -> Never {
    finish(result.rendered(json: json), result.code, json: json)
}

/// For the debug tools, which talk to whoever is working on the protocol.
func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

func note(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func stamp(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%.1f ms", ms)
}

/// The app's version: tvctl lives in RemoteTV.app/Contents/Helpers.
func version() -> String {
    let contents = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    let plist = contents.flatMap { NSDictionary(contentsOf: $0.appending(path: "Info.plist")) }
    return plist?["CFBundleShortVersionString"] as? String ?? "development build"
}

// MARK: - The TV to talk to

@MainActor enum Trace { static var on = false }

/// A session for the Apple TV the command is for (--tv, else the one in use), not yet
/// connected. Without a pairing the command ends here.
@MainActor
func remote(_ inv: Invocation) -> Remote {
    let store = CredentialStore()
    guard let tv = inv.tv ?? store.last, let creds = store.credentials(for: tv) else {
        finish(.failed("no Apple TV is paired yet: tvctl scan, then tvctl pair <tv>"), json: inv.json)
    }
    var c = creds
    if ProcessInfo.processInfo.environment["TVCTL_FAKE_IDENTITY"] != nil {
        // Simulates a TV that forgot us: same TV, an identity it never paired.
        c.clientID = Array(UUID().uuidString.utf8)
        c.clientSeed = (0..<32).map { _ in UInt8.random(in: 0...255) }
    }
    let r = Remote(device: Device(name: tv), credentials: c)
    if inv.direct { r.onTiming = { what, d in note("\(what): \(stamp(d))") } }
    if Trace.on { r.onTrace = { note($0) } }
    return r
}

// MARK: - Through the app

let controlPath = CredentialStore.defaultURL.deletingLastPathComponent().appending(path: "control.sock").path

/// Connects to the app's socket; nil if it isn't listening.
func connectToApp() -> Int32? { UnixSocket.connect(controlPath) }

/// Starts the app in the background and waits (≤5 s) for its socket.
func startApp(json: Bool) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", "com.lingrino.remotetv"]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<100 {
        usleep(50_000)
        if let fd = connectToApp() { return fd }
    }
    finish(.failed("RemoteTV didn't start"), json: json)
}

/// Sends a command line to the app over `fd` and returns its reply and exit status.
func ask(_ fd: Int32, _ args: [String]) -> (String, Int32) {
    let line = Array((args.joined(separator: "\u{1F}") + "\n").utf8)
    _ = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out += buf[0..<n]
    }
    close(fd)
    var text = String(decoding: out, as: UTF8.self)
    var code: Int32 = 1
    if let r = text.range(of: "\u{1F}", options: .backwards) {
        code = Int32(text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        text = String(text[..<r.lowerBound])
    }
    return (text, code)
}

/// A command for the app itself (its window, its choice of TV): asks it and exits.
func toApp(_ fd: Int32, _ inv: Invocation) -> Never {
    let (text, code) = ask(fd, inv.wire)
    finish(text, code, json: inv.json)
}

// MARK: - Commands that act on the TV

/// One-shot commands take turns: two tvctl processes connecting at once would kick each
/// other off the TV. Held until this process exits.
func waitForOtherOneShots() {
    let path = CredentialStore.defaultURL.deletingLastPathComponent().appending(path: "tvctl.lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    if fd >= 0 { _ = flock(fd, LOCK_EX) }   // no pairings folder yet: `remote` says so next
}

/// Has the running app do it, on its session. Returns only when there is no app to ask,
/// or when it is controlling another Apple TV than the one --tv names (then that TV's
/// one connection is free for us).
func tryApp(_ inv: Invocation) {
    guard let fd = connectToApp() else { return }
    let (text, code) = ask(fd, inv.wire)
    if code == TVCommand.otherTV { return }
    finish(text, code, json: inv.json)
}

/// Runs the command on a connection of our own: connect, run it, wait until the TV has
/// received it, close the session the way the app does, exit with the command's status.
@MainActor
func oneShot(_ inv: Invocation) -> Never {
    if !inv.direct {
        waitForOtherOneShots()
        tryApp(inv)   // the app started while we waited
    }
    let r = remote(inv)
    // 10 s: one full connect attempt (8 s), whose failure knocks to wake the TV, and a retry.
    TVCommand.run(inv, on: r, within: 10) { text, code in
        r.flush { delivered in
            r.goodbye {
                guard code == 0, !delivered else { finish(text, code, json: inv.json) }
                finish(.failed("\(r.device.name): the Apple TV didn't confirm it got that"), json: inv.json)
            }
        }
    }
    withExtendedLifetime(r) { dispatchMain() }
}

@MainActor
func onTV(_ inv: Invocation) -> Never {
    if !inv.direct { tryApp(inv) }
    oneShot(inv)
}

// MARK: - The pairings

@MainActor
func scan(_ inv: Invocation) -> Never {
    var seconds = 2.0
    if let a = inv.args.first {
        guard inv.args.count == 1, let s = Double(a), s > 0, s <= 30 else { finish(.misused("scan takes a number of seconds, up to 30", "scan"), json: inv.json) }
        seconds = s
    }
    var found: [Device] = []
    let browser = Browser { found = $0 }
    browser.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated {
            let paired = Set(CredentialStore().entries.map(\.name))
            let width = found.map(\.name.count).max() ?? 0
            let lines = found.map { d in
                d.name + String(repeating: " ", count: width - d.name.count + 2) + d.model + (paired.contains(d.name) ? "  paired" : "  not paired")
            }
            let list = found.map { d -> JSON in ["name": .string(d.name), "model": .string(d.model), "paired": .bool(paired.contains(d.name))] }
            finish(.done(found.isEmpty ? "no Apple TVs found on this network" : lines.joined(separator: "\n"), ["tvs": .array(list)]), json: inv.json)
        }
    }
    withExtendedLifetime(browser) { dispatchMain() }
}

/// Pair-setup from the terminal: the TV shows a PIN, typed here. The prompt goes to
/// stderr, so stdout holds only the result.
@MainActor
func pair(_ inv: Invocation) -> Never {
    guard inv.args.count == 1, let name = inv.args.first else { finish(.misused("pair takes the Apple TV's name (tvctl scan shows it)", "pair"), json: inv.json) }
    let r = Remote(device: Device(name: name), credentials: nil)
    if Trace.on { r.onTrace = { note($0) } }
    r.onPaired = { c in
        var store = CredentialStore()
        do { try store.save(name, c) } catch { finish(.failed("couldn't save the pairing: \(error.localizedDescription)"), json: inv.json) }
        if let fd = connectToApp() { _ = ask(fd, ["reload"]) }   // the running app picks the pairing up
    }
    r.onStatus = { s in
        switch s {
        case .waitingForPIN:
            FileHandle.standardError.write(Data("PIN shown on \(name): ".utf8))
            DispatchQueue.global().async {
                let pin = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                DispatchQueue.main.async { MainActor.assumeIsolated { r.submitPIN(pin) } }
            }
        case .connected:   // paired, and the new pairing works
            r.goodbye { finish(.done("paired with \(name)", ["tv": .string(name)]), json: inv.json) }
        case .failed(let e):
            finish(.failed("\(name): \(e.description)"), json: inv.json)
        default:
            break
        }
    }
    r.pair()
    withExtendedLifetime(r) { dispatchMain() }
}

// MARK: - Debug tools (tvctl help debug)

/// Runs `body` once connected, then exits after `linger` seconds (replies arrive).
@MainActor
func session(_ r: Remote, linger: Double = 0.5, _ body: @escaping @MainActor () -> Void) -> Never {
    r.onStatus = { s in
        switch s {
        case .connected:
            body()
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
                print("power: \(r.power)")
                exit(0)
            }
        case .failed(let e): die(e.description)
        case .unpaired: die("\(r.device.name) doesn't recognize this pairing anymore: tvctl pair \(r.device.name)")
        default: break
        }
    }
    r.connect()
    withExtendedLifetime(r) { dispatchMain() }
}

@MainActor
func debug(_ inv: Invocation) -> Never {
    guard let tool = inv.args.first else { finish(.done(TVCommand.Help.debug), json: false) }
    let args = Array(inv.args.dropFirst())
    var direct = inv
    direct.direct = true   // the tools below print timings and use their own connection
    switch tool {
    case "raw":
        var raw = inv
        raw.command = "raw"
        raw.args = args
        onTV(raw)

    case "snapshot":
        var shot = inv
        shot.command = "snapshot"
        shot.args = args
        toApp(connectToApp() ?? startApp(json: inv.json), shot)

    case "event":
        guard let id = args.first else { die("usage: tvctl debug event <name> [key=value...]") }
        let content: [String: OPACK.Value]
        switch OPACK.arguments(args.dropFirst()) {
        case .success(let c): content = c
        case .failure(let e): die(e.description)
        }
        let r = remote(direct)
        session(r, linger: 1.5) { r.raw(id, content, event: true) }

    case "listen":
        guard let secs = args.first.flatMap(Double.init) else { die("usage: tvctl debug listen <seconds> [event...] [+request...] [!button...]") }
        let rest = args.dropFirst()
        let events = rest.filter { !$0.hasPrefix("+") && !$0.hasPrefix("!") }
        let requests = rest.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
        let presses = rest.filter { $0.hasPrefix("!") }.compactMap { Button.named(String($0.dropFirst())) }
        let r = remote(direct)
        let dump = ProcessInfo.processInfo.environment["TVCTL_DUMP"]
        var n = 0
        r.onTrace = { line in if line.hasPrefix("←") { print(line.replacing("RemoteCore.OPACK.Value.", with: "").prefix(400)); fflush(stdout) } }
        r.onMessage = { msg in
            // TVCTL_DUMP=dir: write every binary plist in a received message to dir/N.plist.
            guard let dump else { return }
            func walk(_ v: OPACK.Value) {
                switch v {
                case .data(let d) where d.starts(with: Array("bplist".utf8)):
                    n += 1
                    let path = "\(dump)/\(n).plist"
                    FileManager.default.createFile(atPath: path, contents: Data(d))
                    print("  wrote \(path)")
                case .dict(let m): m.values.forEach(walk)
                case .array(let a): a.forEach(walk)
                default: break
                }
            }
            walk(msg)
        }
        session(r, linger: secs) {
            if !events.isEmpty { r.raw("_interest", ["_regEvents": .array(events.map { .string($0) })], event: true) }
            for q in requests { r.raw(q, [:]) }
            for (i, b) in presses.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 * Double(i + 1)) { print("press \(b)"); r.press(b) }
            }
        }

    case "airplay":
        // Opens the AirPlay remote-control tunnel and prints raw MRP messages (5 s).
        let store = CredentialStore()
        guard let name = inv.tv ?? store.last, let creds = store.credentials(for: name) else { die("no Apple TV is paired") }
        let t = AirPlayTunnel(device: Device(name: name), credentials: creds)
        let start = ContinuousClock.now
        t.onState = { s in print("\(stamp(ContinuousClock.now - start)) state: \(s)"); if case .failed = s { exit(1) } }
        t.onMessage = { m in print("message \(m.count) B: \(m.prefix(24).map { String(format: "%02x", $0) }.joined())") }
        t.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        withExtendedLifetime(t) { dispatchMain() }

    case "mrp":
        // MRP over the AirPlay tunnel alone: `mrp [seconds]` prints now playing and message
        // types; `mrp mute` toggles mute; `mrp seek <s>` seeks to an absolute position.
        let store = CredentialStore()
        guard let name = inv.tv ?? store.last, let creds = store.credentials(for: name) else { die("no Apple TV is paired") }
        let action = args.first.flatMap { ["mute", "seek"].contains($0) ? $0 : nil }
        let number = (action == nil ? args.first : args.dropFirst().first).flatMap(Double.init)
        if action == "seek" && number == nil { die("usage: tvctl debug mrp seek <seconds>") }
        let m = MediaRemote(device: Device(name: name), credentials: creds)
        let start = ContinuousClock.now
        if Trace.on { m.onTrace = { print("  \($0)") }; m.tunnel.onTrace = { print("  \($0)") } }
        m.onTunnel = { s in
            print("\(stamp(ContinuousClock.now - start)) tunnel: \(s)")
            if case .failed = s { exit(1) }
        }
        m.onNowPlaying = { np in
            guard let np else { print("\(stamp(ContinuousClock.now - start)) nothing playing"); return }
            print("\(stamp(ContinuousClock.now - start)) \(np.title ?? "?")\(np.subtitle.map { " — \($0)" } ?? "")  \(Int(np.position()))s / \(np.duration.map { "\(Int($0))s" } ?? "live")  rate \(np.rate) state \(np.state)  seek \(m.supports(45))  subtitles \(np.hasCaptions ? (np.captionsEnabled ? "on" : "off") : "none")")
        }
        m.onReady = { ok in
            print("\(stamp(ContinuousClock.now - start)) ready: \(ok)")
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if action == "mute" { print("mute"); m.toggleMute() }
                if action == "seek", let to = number { print("seek \(to)"); m.seek(to: to) }
            }
        }
        m.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? (number ?? 4) : 3)) { exit(0) }
        withExtendedLifetime(m) { dispatchMain() }

    default:
        finish(.misused("unknown debug tool \"\(tool)\" (tvctl help debug)"), json: inv.json)
    }
}

// MARK: - Main

MainActor.assumeIsolated {
    var inv = Invocation(Array(CommandLine.arguments.dropFirst()))
    let json = inv.json
    if let problem = inv.problem { finish(.misused(problem), json: json) }
    if inv.verbose {
        inv.direct = true
        Trace.on = true
    }
    if inv.version {
        let v = version()
        finish(.done("tvctl \(v)", ["version": .string(v)]), json: json)
    }
    guard let cmd = inv.command, !inv.help else {
        guard let topic = inv.command else { finish(.done(TVCommand.Help.overview, TVCommand.Help.catalog), json: json) }
        guard let text = TVCommand.Help.text(for: topic) else { finish(.misused(TVCommand.Help.unknown(topic)), json: json) }
        let about: JSON = TVCommand.Help.entry(topic).map {
            ["name": .string($0.name), "usage": .string("tvctl " + $0.usage), "summary": .string($0.summary), "help": .string(text)]
        } ?? ["help": .string(text)]
        finish(.done(text, about), json: json)
    }

    let store = CredentialStore()
    if let want = inv.tv {
        guard let name = store.name(matching: want) else { finish(.failed("\"\(want)\" isn't a paired Apple TV (tvctl tvs lists them)"), json: json) }
        inv.tv = name
    }

    switch cmd {
    case "tvs":
        guard inv.args.isEmpty else { finish(.misused("tvs takes no arguments", "tvs"), json: json) }
        let names = store.entries.map(\.name)
        let lines = names.map { ($0 == store.last ? "* " : "  ") + $0 }
        let list = names.map { n -> JSON in ["name": .string(n), "in_use": .bool(n == store.last)] }
        finish(.done(names.isEmpty ? "no Apple TV is paired yet: tvctl scan, then tvctl pair <tv>" : lines.joined(separator: "\n"),
                     ["tvs": .array(list)]), json: json)

    case "scan":
        scan(inv)

    case "pair":
        pair(inv)

    case "use", "forget":
        guard inv.args.count == 1 else { finish(.misused("\(cmd) takes the name of a paired Apple TV (tvctl tvs)", cmd), json: json) }
        guard let name = store.name(matching: inv.args[0]) else { finish(.failed("\"\(inv.args[0])\" isn't a paired Apple TV (tvctl tvs lists them)"), json: json) }
        inv.args = [name]
        if let fd = connectToApp() { toApp(fd, inv) }   // the app switches (or lets go) too
        var pairings = store
        do {
            if cmd == "use" { try pairings.touch(name) } else { try pairings.remove(name) }
        } catch {
            finish(.failed("couldn't update the pairings: \(error.localizedDescription)"), json: json)
        }
        finish(.done(cmd == "use" ? "using \(name)" : "forgot \(name)", ["tv": .string(name)]), json: json)

    case "show", "sidebar":
        toApp(connectToApp() ?? startApp(json: json), inv)

    case "hide":   // nothing to hide when the app isn't running
        if let fd = connectToApp() { toApp(fd, inv) }
        finish(.done(), json: json)

    case "debug":
        debug(inv)

    default:
        // Everything else acts on the TV. Checked here so a typo ends without a connection.
        guard TVCommand.Help.entry(cmd) != nil else { finish(.misused(TVCommand.Help.unknown(cmd)), json: json) }
        onTV(inv)
    }
}
