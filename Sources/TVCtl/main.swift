import Foundation
import RemoteCore

// tvctl: the RemoteTV command line. Installed with the app (a symlink in ~/.local/bin).
//
// Normal commands go to the running app over its control socket and use the app's own
// session (no handshake, no fighting over the TV's one connection per pairing); the app
// is started in the background if it isn't running. See `tvctl help`.
//
// `tvctl direct …` talks to the TV itself (its own connection, which kicks the app's off
// while it runs): protocol work and debugging. `scan` and `pair` are always direct.

func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

func stamp(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%.1f ms", ms)
}

@MainActor
func remote(_ name: String?) -> Remote {
    let store = CredentialStore()
    guard let tv = name ?? store.last else { die("no paired Apple TV: tvctl pair <name>") }
    guard let creds = store.credentials(for: tv) else { die("\(tv) isn't paired: tvctl pair \(tv)") }
    var c = creds
    if ProcessInfo.processInfo.environment["TVCTL_FAKE_IDENTITY"] != nil {
        // Simulates a TV that forgot us: same TV, an identity it never paired.
        c.clientID = Array(UUID().uuidString.utf8)
        c.clientSeed = (0..<32).map { _ in UInt8.random(in: 0...255) }
    }
    let r = Remote(device: Device(name: tv), credentials: c)
    r.onTiming = { what, d in print("\(what): \(stamp(d))") }
    if Trace.on { r.onTrace = { print($0); fflush(stdout) } }
    return r
}

@MainActor enum Trace { static var on = false }

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

// MARK: - Through the app

let controlPath = CredentialStore.defaultURL.deletingLastPathComponent().appending(path: "control.sock").path

/// Connects to the app's socket; nil if it isn't listening.
func connectToApp() -> Int32? { UnixSocket.connect(controlPath) }

/// Sends a command to the app (starting it if needed), prints its reply, exits with its code.
func viaApp(_ args: [String]) -> Never {
    var fd = connectToApp()
    if fd == nil {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", "com.lingrino.remotetv"]
        try? p.run()
        p.waitUntilExit()
        for _ in 0..<100 where fd == nil {
            usleep(50_000)
            fd = connectToApp()
        }
    }
    guard let fd else { die("RemoteTV isn't running and didn't start") }
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
    if code == 0 { FileHandle.standardOutput.write(Data(text.utf8)) } else { FileHandle.standardError.write(Data(text.utf8)) }
    exit(code)
}

do {
    let all = Array(CommandLine.arguments.dropFirst())
    let first = all.first ?? "help"
    if first != "direct" && first != "scan" && first != "pair" && first != "-v" {
        viaApp(all.isEmpty ? ["help"] : all)
    }
}

// MARK: - Direct (own connection)

MainActor.assumeIsolated {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.first == "direct" { args.removeFirst() }
    let verbose = args.first == "-v"
    if verbose { args.removeFirst() }
    Trace.on = verbose
    guard !args.isEmpty else { die("usage: tvctl scan | pair <tv> | status [tv] | press [tv:] <button>... | skip [tv:] <s> | sleep|wake [tv]") }
    let cmd = args.removeFirst()
    // "tv:" prefix picks the Apple TV for commands that take a list.
    var tv: String? = nil
    if let first = args.first, first.hasSuffix(":") {
        tv = String(first.dropLast())
        args.removeFirst()
    }
    switch cmd {
    case "scan":
        let b = Browser { devices in
            for d in devices { print("\(d.name)\t\(d.model)") }
        }
        b.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        withExtendedLifetime(b) { dispatchMain() }

    case "pair":
        guard let name = args.first ?? tv else { die("usage: tvctl pair <tv>") }
        let r = Remote(device: Device(name: name), credentials: nil)
        r.onPaired = { c in
            var store = CredentialStore()
            do { try store.save(name, c) } catch { die("couldn't save the pairing: \(error)") }
            print("paired with \(name)")
            if let fd = connectToApp() {   // the running app picks the pairing up
                let line = Array("reload\n".utf8)
                _ = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        }
        r.onTiming = { what, d in print("\(what): \(stamp(d))") }
        r.onStatus = { s in
            print("status: \(s)")
            switch s {
            case .waitingForPIN:
                print("PIN: ", terminator: "")
                fflush(stdout)
                DispatchQueue.global().async {
                    let pin = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                    DispatchQueue.main.async { MainActor.assumeIsolated { r.submitPIN(pin) } }
                }
            case .connected:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("power: \(r.power)"); exit(0) }
            case .failed(let e): die(e.description)
            default: break
            }
        }
        r.pair()
        withExtendedLifetime(r) { dispatchMain() }

    case "status":
        let r = remote(args.first ?? tv)
        session(r, linger: 1) {}

    case "press":
        let list = args.map { a -> Button in
            guard let b = Button.named(a) else { die("unknown button \(a)") }
            return b
        }
        let r = remote(tv)
        session(r) { for b in list { r.press(b) } }

    case "skip":
        guard let s = args.first.flatMap(Double.init) else { die("usage: tvctl skip [tv:] <seconds>") }
        let r = remote(tv)
        session(r) { r.skip(s) }

    case "raw", "event":
        // tvctl raw <_i> [key=value …]: value is an int, a double (has a "."), true/false,
        // or a string. Prints the reply. `event` sends it as an event (no reply).
        guard let id = args.first else { die("usage: tvctl raw <_i> [key=value …]") }
        let content: [String: OPACK.Value]
        switch OPACK.arguments(args.dropFirst()) {
        case .success(let c): content = c
        case .failure(let e): die(e.description)
        }
        let r = remote(tv)
        session(r, linger: 1.5) {
            r.raw(id, content, event: cmd == "event") { reply, err in
                if let err { print("error: \(err)") } else { print(reply.map { "\($0)" } ?? "nil") }
            }
        }

    case "listen":
        // tvctl listen <seconds> [event…] [+request…]: registers interest in the events,
        // sends the +requests, and prints everything received (trace) for <seconds>.
        guard let secs = args.first.flatMap(Double.init) else { die("usage: tvctl listen <seconds> [event…] [+request…]") }
        let rest = args.dropFirst()
        let events = rest.filter { !$0.hasPrefix("+") && !$0.hasPrefix("!") }
        let requests = rest.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
        let presses = rest.filter { $0.hasPrefix("!") }.compactMap { Button.named(String($0.dropFirst())) }
        let r = remote(tv)
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

    case "np":
        // Now playing, as the app sees it.
        let r = remote(args.first ?? tv)
        r.onNowPlaying = { np in
            guard let np else { print("nothing playing"); return }
            let pos = np.position()
            print("\(np.title ?? "?")\(np.subtitle.map { " — \($0)" } ?? "")  \(Int(pos))s / \(Int(np.duration ?? 0))s  rate \(np.rate) state \(np.state)  captions \(np.captionsEnabled ? "on" : "off")\(np.hasCaptions ? "" : " (none)")  \(np.bundleID ?? "")  artwork \(np.artwork?.count ?? 0) B")
        }
        session(r, linger: 1.5) {}

    case "seek":
        guard let to = args.first.flatMap(Double.init) else { die("usage: tvctl seek [tv:] <seconds>") }
        let r = remote(tv)
        var done = false
        r.onNowPlaying = { np in
            guard !done, let np else { return }
            done = true
            print("at \(Int(np.position()))s → \(Int(to))s")
            r.seek(to: to)
        }
        session(r, linger: 2) {}

    case "captions":
        let r = remote(args.first ?? tv)
        session(r) { r.toggleCaptions() }

    case "text":
        // Replaces the focused TV text field's contents (waits up to 3 s for the session).
        let text = args.joined(separator: " ")
        let r = remote(tv)
        r.onTextSession = { s in
            guard let s else { print("no text field focused"); return }
            print("text field had \"\(s.text)\"")
            r.setText(text)
        }
        session(r, linger: 2) {}

    case "airplay":
        // Opens the AirPlay remote-control tunnel and prints raw MRP messages (5 s).
        let store = CredentialStore()
        guard let name = tv ?? args.first ?? store.last, let creds = store.credentials(for: name) else { die("not paired") }
        let t = AirPlayTunnel(device: Device(name: name), credentials: creds)
        let start = ContinuousClock.now
        t.onState = { s in print("\(stamp(ContinuousClock.now - start)) state: \(s)"); if case .failed = s { exit(1) } }
        t.onMessage = { m in print("message \(m.count) B: \(m.prefix(24).map { String(format: "%02x", $0) }.joined())") }
        t.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        withExtendedLifetime(t) { dispatchMain() }

    case "mrp", "mute", "mseek":
        // MRP over the AirPlay tunnel: `mrp [seconds]` prints now playing and message types;
        // `mute` toggles mute; `mseek <s>` seeks to an absolute position.
        let store = CredentialStore()
        guard let name = tv ?? store.last, let creds = store.credentials(for: name) else { die("not paired") }
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
        let arg = args.first.flatMap(Double.init)
        m.onReady = { ok in
            print("\(stamp(ContinuousClock.now - start)) ready: \(ok)")
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if cmd == "mute" { print("mute"); m.toggleMute() }
                if cmd == "mseek", let to = arg { print("seek \(to)"); m.seek(to: to) }
            }
        }
        m.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (cmd == "mrp" ? (arg ?? 4) : 3)) { exit(0) }
        withExtendedLifetime(m) { dispatchMain() }

    case "sleep", "wake":
        let r = remote(args.first ?? tv)
        session(r) { cmd == "sleep" ? r.sleep() : r.wake() }

    default:
        die("unknown command \(cmd)")
    }
}
