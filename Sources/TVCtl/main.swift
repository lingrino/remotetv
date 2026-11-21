import Foundation
import RemoteCore

// tvctl: command-line client over RemoteCore, for exercising the protocol against a real
// Apple TV without the UI. Shares the app's pairing store.
//   tvctl scan                       list Apple TVs on the network (3 s)
//   tvctl pair <tv>                  pair: the TV shows a PIN, type it on stdin
//   tvctl status [tv]                connect, print timings, power state, controls
//   tvctl press [tv:] <button>...    click buttons (up down left right select menu home
//                                    playpause volumeup volumedown …), e.g. `tvctl press down select`
//   tvctl skip [tv:] <seconds>       skip playback (negative = back)
//   tvctl sleep|wake [tv]

func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

func stamp(_ d: Duration) -> String {
    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%.1f ms", ms)
}

let buttons: [String: Button] = [
    "up": .up, "down": .down, "left": .left, "right": .right, "select": .select, "menu": .menu,
    "back": .menu, "home": .home, "tv": .home, "volumeup": .volumeUp, "volumedown": .volumeDown,
    "playpause": .playPause, "siri": .siri, "screensaver": .screensaver, "guide": .guide,
    "pageup": .pageUp, "pagedown": .pageDown, "channelup": .channelUp, "channeldown": .channelDown,
]

@MainActor
func remote(_ name: String?) -> Remote {
    let store = CredentialStore()
    guard let tv = name ?? store.last else { die("no paired Apple TV: tvctl pair <name>") }
    guard let creds = store.credentials(for: tv) else { die("\(tv) isn't paired: tvctl pair \(tv)") }
    let r = Remote(device: Device(name: tv), credentials: creds)
    r.onTiming = { what, d in print("\(what): \(stamp(d))") }
    return r
}

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
        case .failed(let e): die(e)
        default: break
        }
    }
    r.connect()
    withExtendedLifetime(r) { dispatchMain() }
}

MainActor.assumeIsolated {
    var args = Array(CommandLine.arguments.dropFirst())
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
            case .failed(let e): die(e)
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
            guard let b = buttons[a.lowercased()] else { die("unknown button \(a)") }
            return b
        }
        let r = remote(tv)
        session(r) { for b in list { r.press(b) } }

    case "skip":
        guard let s = args.first.flatMap(Double.init) else { die("usage: tvctl skip [tv:] <seconds>") }
        let r = remote(tv)
        session(r) { r.skip(s) }

    case "sleep", "wake":
        let r = remote(args.first ?? tv)
        session(r) { cmd == "sleep" ? r.sleep() : r.wake() }

    default:
        die("unknown command \(cmd)")
    }
}
