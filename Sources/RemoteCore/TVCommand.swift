import Foundation

/// tvctl's command line: how arguments are read (`Invocation`), what a command prints
/// (`Result`), and the commands that act on the TV. Shared so that a command means the
/// same thing both ways it can run: on the app's session when RemoteTV is running
/// (ControlServer), and on a connection tvctl makes for the one command when it isn't.
/// The words people read (the command list, each command's help) are in TVCommand+Help.
///
/// A command is parsed first (a typo never touches the TV), then gets a session (starting
/// one if needed), then waits for what it reads from the TV (`Remote.knows`), then runs.
@MainActor
public enum TVCommand {
    public typealias Reply = @MainActor (String, Int32) -> Void

    // MARK: - Exit status

    /// The command was understood but didn't work: the message says why.
    public nonisolated static let failed: Int32 = 1
    /// The command line wasn't understood.
    public nonisolated static let misused: Int32 = 2
    /// Only from the app to tvctl, never shown: `--tv` names an Apple TV the app isn't
    /// controlling, so tvctl reaches that one itself.
    public nonisolated static let otherTV: Int32 = 75

    // MARK: - Reading the command line

    /// A command line taken apart: tvctl's own options (anywhere before a `--`), the
    /// command under its one real name, and the command's arguments.
    public struct Invocation: Sendable, Equatable {
        public var tv: String?
        public var json = false
        /// Debugging: use tvctl's own connection even while the app runs.
        public var direct = false
        /// Debugging: print every message (implies `direct`).
        public var verbose = false
        /// Help was asked for, about `command` if there is one.
        public var help = false
        public var version = false
        public var command: String?
        public var args: [String] = []
        /// An option that can't be read ("--tv" with no name).
        public var problem: String?

        /// Other names for commands: shorthand, and what the first version called them.
        static let aliases: [String: (String, [String])] = [
            "np": ("playing", []), "now-playing": ("playing", []), "nowplaying": ("playing", []),
            "up-next": ("upnext", []), "subtitles": ("captions", []), "open": ("launch", []),
            "unpair": ("forget", []), "wake": ("power", ["on"]), "sleep": ("power", ["off"]),
        ]

        public init(_ argv: [String]) {
            var words: [String] = []
            var literal = false
            var i = 0
            while i < argv.count {
                let a = argv[i]
                i += 1
                if literal {
                    words.append(a)
                    continue
                }
                switch a {
                case "--": literal = true
                case "--json": json = true
                case "--direct": direct = true
                case "-v", "--verbose": verbose = true
                case "-h", "--help": help = true
                case "--version": version = true
                case "--tv":
                    if i < argv.count {
                        tv = argv[i]
                        i += 1
                    } else {
                        problem = "--tv needs the name of a paired Apple TV (tvctl tvs)"
                    }
                default:
                    if a.hasPrefix("--tv=") { tv = String(a.dropFirst(5)) } else { words.append(a) }
                }
            }
            if words.first == "help" {   // "tvctl help press" = "tvctl press --help"
                help = true
                words.removeFirst()
            }
            guard let first = words.first else { return }
            let (name, extra) = Invocation.aliases[first] ?? (first, [])
            command = name
            args = extra + words.dropFirst()
        }

        /// The same command line for the app: the options, then `--` so that nothing among
        /// the command's own arguments is read as an option a second time.
        public var wire: [String] {
            var out: [String] = []
            if json { out.append("--json") }
            if let tv { out += ["--tv", tv] }
            out.append("--")
            if let command { out.append(command) }
            return out + args
        }
    }

    // MARK: - What a command says

    /// A command's outcome: the exit status, the text for a person, and for `--json` the
    /// members that follow `"ok": true`.
    public struct Result: Sendable, Equatable {
        public var code: Int32
        public var text: String
        public var fields: JSON

        public static func done(_ text: String = "", _ fields: JSON = [:]) -> Result {
            Result(code: 0, text: text, fields: fields)
        }

        public static func failed(_ message: String) -> Result { Result(code: TVCommand.failed, text: message, fields: [:]) }

        /// Not understood: the complaint, then the command's usage line when it has one.
        public static func misused(_ message: String, _ command: String? = nil) -> Result {
            var text = message
            if let e = command.flatMap(Help.entry) { text += "\nusage: tvctl \(e.usage)   (more: tvctl help \(e.name))" }
            return Result(code: TVCommand.misused, text: text, fields: [:])
        }

        /// What to print: the text, or with `--json` one object on one line,
        /// `{"ok":true,…}` or `{"ok":false,"error":"…"}`.
        public func rendered(json: Bool) -> String {
            guard json else { return text }
            if code == 0 { return JSON.object([JSON.Member(key: "ok", value: true)] + fields.members).text }
            return (["ok": false, "error": .string(text)] as JSON).text
        }
    }

    // MARK: - Running

    /// Runs a command line on `r` and replies exactly once with what to print and the exit
    /// status. `seconds` is how long to keep trying for a session.
    public static func run(_ argv: [String], on r: Remote, within seconds: Double = 5, reply: @escaping Reply) {
        run(Invocation(argv), on: r, within: seconds, reply: reply)
    }

    public static func run(_ inv: Invocation, on r: Remote, within seconds: Double = 5, reply: @escaping Reply) {
        let finish: Done = { reply($0.rendered(json: inv.json), $0.code) }
        if let problem = inv.problem { return finish(.misused(problem)) }
        guard let cmd = inv.command else { return finish(.misused("no command given (tvctl help)")) }
        let plan: Plan
        switch parse(cmd, inv.args) {
        case .misuse(let result): return finish(result)
        case .plan(let p): plan = p
        }
        connect(r, within: seconds) { problem in
            if let problem { return finish(.failed("\(r.device.name): \(problem)")) }
            // `knows` bounds its own waits; the timeout here only backstops it.
            poll(for: 4, until: { r.knows(plan.needs) || r.status != .connected }, then: { _ in
                guard r.status == .connected else { return finish(.failed("\(r.device.name): \(describe(r.status))")) }
                plan.run(r, finish)
            })
        }
    }

    // MARK: - Commands

    typealias Done = @MainActor (Result) -> Void

    struct Plan {
        let needs: Remote.Knowledge
        let run: @MainActor (Remote, @escaping Done) -> Void
    }

    enum Parsed {
        case plan(Plan)
        case misuse(Result)

        static func run(_ needs: Remote.Knowledge = .session, _ run: @escaping @MainActor (Remote, @escaping Done) -> Void) -> Parsed {
            .plan(Plan(needs: needs, run: run))
        }
    }

    private enum Step {
        case button(Button)
        case wait(Double)
    }

    /// The longest a command may take by its own design (pauses in `press`, a `hold`): the
    /// app answers tvctl within 15 s.
    static let longest: Double = 10

    static func parse(_ cmd: String, _ rest: [String]) -> Parsed {
        func misuse(_ message: String) -> Parsed { .misuse(.misused(message, cmd)) }
        let extra: Parsed? = rest.isEmpty ? nil : misuse("\(cmd) takes no arguments")

        switch cmd {
        case "press":
            var steps: [Step] = []
            for a in rest {
                if let b = Button.named(a) {
                    steps.append(.button(b))
                } else if let s = Double(a), s.isFinite, s >= 0 {
                    steps.append(.wait(s))
                } else {
                    return misuse("unknown button \"\(a)\"")
                }
            }
            guard steps.contains(where: { if case .button = $0 { true } else { false } }) else { return misuse("no button to press") }
            let waits = steps.reduce(0.0) { if case .wait(let s) = $1 { $0 + s } else { $0 } }
            guard waits <= longest else { return misuse("the pauses add up to more than \(Int(longest)) seconds") }
            return .run { r, done in
                var i = 0
                @MainActor func next() {
                    while i < steps.count {
                        let step = steps[i]
                        i += 1
                        switch step {
                        case .button(let b): r.press(b)
                        case .wait(let s):
                            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { next() } }
                            return
                        }
                    }
                    done(.done())
                }
                next()
            }

        case "hold":
            guard let b = rest.first.flatMap(Button.named) else { return misuse(rest.isEmpty ? "no button to hold" : "unknown button \"\(rest[0])\"") }
            var secs = 1.0
            if rest.count > 1 {
                guard rest.count == 2, let s = Double(rest[1]), s > 0, s <= longest else { return misuse("hold for up to \(Int(longest)) seconds") }
                secs = s
            }
            return .run { r, done in
                r.button(b, down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                    MainActor.assumeIsolated {
                        r.button(b, down: false)
                        done(.done())
                    }
                }
            }

        case "playing":
            if let extra { return extra }
            return .run(.playing) { r, done in
                guard let np = r.nowPlaying else { return done(.done("nothing is playing", ["now_playing": nil])) }
                done(.done(describe(np), ["now_playing": json(np)]))
            }

        case "play", "pause":
            if let extra { return extra }
            let play = cmd == "play"
            return .run(.playing) { r, done in
                guard let np = r.nowPlaying else {
                    // Nothing reported: nothing to pause; Play is still the remote's button
                    // (it starts what's selected).
                    if play { r.press(.playPause) }
                    return done(play ? .done("", ["changed": true]) : .done("nothing is playing", ["changed": false]))
                }
                guard np.isPlaying != play else { return done(.done("already \(play ? "playing" : "paused")", ["changed": false])) }
                r.press(.playPause)
                done(.done("", ["changed": true]))
            }

        case "playpause":
            if let extra { return extra }
            return .run { r, done in
                r.press(.playPause)
                done(.done())
            }

        case "skip":
            guard rest.count == 1, let s = Double(rest[0]), s.isFinite, s != 0 else { return misuse("skip takes a number of seconds, negative to go back") }
            return .run { r, done in
                r.skip(s)
                done(.done())
            }

        case "seek":
            guard rest.count == 1, let s = seconds(rest[0]) else { return misuse("seek takes a position: seconds, m:ss or h:mm:ss") }
            return .run(.playing) { r, done in
                guard r.nowPlaying != nil else { return done(.failed("nothing is playing")) }
                r.seek(to: s)
                done(.done())
            }

        case "volume":
            guard let way = rest.first, way == "up" || way == "down" else { return misuse("volume goes up or down") }
            var steps = 1
            if rest.count > 1 {
                guard rest.count == 2, let n = Int(rest[1]), (1...20).contains(n) else { return misuse("volume moves 1 to 20 steps at a time") }
                steps = n
            }
            return .run { r, done in
                for _ in 0..<steps { r.press(way == "up" ? .volumeUp : .volumeDown) }
                done(.done())
            }

        case "mute":
            if let extra { return extra }
            return .run(.link) { r, done in
                guard r.muteAvailable else { return done(.failed("mute needs the AirPlay link to the Apple TV, which isn't up")) }
                r.toggleMute()
                done(.done())
            }

        case "captions":
            guard rest.count <= 1, rest.first.map({ $0 == "on" || $0 == "off" }) ?? true else { return misuse("captions takes on, off, or nothing (toggle)") }
            guard let want = rest.first.map({ $0 == "on" }) else {
                return .run { r, done in
                    r.toggleCaptions()
                    done(.done())
                }
            }
            return .run(.playing) { r, done in
                guard let np = r.nowPlaying else { return done(.failed("nothing is playing")) }
                // Only some apps say whether subtitles are on (the TV app does).
                guard np.hasCaptions else { return done(.failed("this app doesn't say whether subtitles are on; `tvctl captions` toggles them")) }
                guard np.captionsEnabled != want else { return done(.done("subtitles are already \(want ? "on" : "off")", ["changed": false])) }
                r.toggleCaptions()
                done(.done("", ["changed": true]))
            }

        case "type":
            guard !rest.isEmpty else { return misuse("nothing to type") }
            let t = rest.joined(separator: " ")
            return .run(.state) { r, done in
                guard r.textSession != nil else { return done(.failed("no text field is focused on the TV")) }
                r.editText(delete: 0, insert: t)
                done(.done())
            }

        case "text":
            let new = rest.isEmpty ? nil : rest.joined(separator: " ")
            return .run(.state) { r, done in
                guard let field = r.textSession else { return done(.failed("no text field is focused on the TV")) }
                guard let new else { return done(.done(field.text, ["text": .string(field.text)])) }
                r.setText(new)
                done(.done())
            }

        case "apps":
            if let extra { return extra }
            return .run { r, done in
                r.fetchApps(icons: false) { apps in
                    guard !apps.isEmpty else { return done(.failed("the Apple TV didn't list its apps")) }
                    let width = apps.map(\.name.count).max() ?? 0
                    let lines = apps.map { $0.name + String(repeating: " ", count: width - $0.name.count + 2) + $0.bundleID }
                    done(.done(lines.joined(separator: "\n"), ["apps": .array(apps.map(json))]))
                }
            }

        case "launch":
            guard !rest.isEmpty else { return misuse("nothing to launch") }
            let target = rest.joined(separator: " ")
            if target.contains("://") {
                return .run { r, done in
                    r.open(url: target)
                    done(.done("", ["launched": ["url": .string(target)]]))
                }
            }
            return .run { r, done in
                r.fetchApps(icons: false) { apps in
                    switch find(target, in: apps) {
                    case .one(let app):
                        r.launch(bundleID: app.bundleID)
                        done(.done("", ["launched": json(app)]))
                    case .several(let found):
                        done(.failed("\"\(target)\" could be \(found.map(\.name).joined(separator: ", ")): say more of the name"))
                    case .none where apps.isEmpty && target.contains(".") && !target.contains(" "):
                        // No list to check against: a bundle id can still be tried as given.
                        r.launch(bundleID: target)
                        done(.done("", ["launched": ["name": nil, "bundle_id": .string(target)]]))
                    case .none:
                        done(.failed(apps.isEmpty ? "the Apple TV didn't list its apps" : "no app called \"\(target)\" on \(r.device.name) (tvctl apps)"))
                    }
                }
            }

        case "upnext":
            var pick: Int?
            if !rest.isEmpty {
                guard rest.count == 1, let n = Int(rest[0]), n >= 1 else { return misuse("upnext takes an item's number from its list") }
                pick = n
            }
            return .run { r, done in
                r.fetchUpNext { items in
                    guard let items else { return done(.failed("the Apple TV couldn't list Up Next right now")) }
                    guard let pick else {
                        let lines = items.enumerated().map { i, item in
                            let about = [item.subtitle, item.service, item.reason].compactMap { $0 }.joined(separator: " · ")
                            return "\(i + 1 < 10 && items.count >= 10 ? " " : "")\(i + 1)  \(item.title)\(about.isEmpty ? "" : "  (\(about))")"
                        }
                        return done(.done(items.isEmpty ? "Up Next is empty" : lines.joined(separator: "\n"),
                                          ["items": .array(items.enumerated().map { json($1, number: $0 + 1) })]))
                    }
                    guard pick <= items.count else { return done(.failed("Up Next has \(items.count) item\(items.count == 1 ? "" : "s")")) }
                    let item = items[pick - 1]
                    guard let url = item.actionURL else { return done(.failed("\"\(item.title)\" has nothing to open")) }
                    r.open(url: url)
                    done(.done("", ["played": json(item, number: pick)]))
                }
            }

        case "status":
            if let extra { return extra }
            return .run(.playing) { r, done in
                let report: @MainActor () -> Void = { done(.done(status(r).joined(separator: "\n"), statusJSON(r))) }
                // The control flags come as an event a new session may not have had yet:
                // flush's request asks for them.
                if r.controlsKnown { report() } else { r.flush { _ in report() } }
            }

        case "power":
            guard rest.count <= 1, let way = ["": 0, "on": 1, "off": 2, "toggle": 3][rest.first ?? ""] else { return misuse("power takes on, off, toggle, or nothing (show)") }
            switch way {
            case 1:
                return .run { r, done in
                    r.wake()
                    done(.done())
                }
            case 2:
                return .run { r, done in
                    r.sleep()
                    done(.done())
                }
            default:   // showing and toggling both need to know which it is
                return .run(.state) { r, done in
                    guard way == 3 else { return done(.done(describe(r.power), ["power": .string(describe(r.power))])) }
                    r.togglePower()
                    done(.done())
                }
            }

        case "raw":   // tvctl debug raw
            guard let id = rest.first else { return .misuse(.misused("usage: tvctl debug raw <request> [key=value...]")) }
            let content: [String: OPACK.Value]
            switch OPACK.arguments(rest.dropFirst()) {
            case .success(let c): content = c
            case .failure(let e): return .misuse(.misused(e.description))
            }
            return .run { r, done in
                r.raw(id, content) { value, error in
                    if let error { return done(.failed(error)) }
                    let text = value.map { "\($0)" }?.replacing("RemoteCore.OPACK.Value.", with: "") ?? ""
                    done(.done(text, ["reply": .string(text)]))
                }
            }

        default:
            return .misuse(.misused(Help.unknown(cmd)))
        }
    }

    // MARK: - Finding an app

    enum Match: Equatable {
        case one(TVApp)
        case several([TVApp])
        case none
    }

    /// The app meant by `query`: its bundle id or its name (any case), else the one app
    /// whose name starts with it, else the one whose name contains it.
    nonisolated static func find(_ query: String, in apps: [TVApp]) -> Match {
        let q = query.lowercased()
        if let exact = apps.first(where: { $0.bundleID.lowercased() == q }) ?? apps.first(where: { $0.name.lowercased() == q }) {
            return .one(exact)
        }
        for test: (String) -> Bool in [{ $0.hasPrefix(q) }, { $0.contains(q) }] {
            let found = apps.filter { test($0.name.lowercased()) }
            if found.count == 1 { return .one(found[0]) }
            if found.count > 1 { return .several(found) }
        }
        return .none
    }

    // MARK: - Getting a session

    /// Waits for a session, starting one if there is none and retrying a failed connect
    /// (after 0.3 s, 1 s, 2 s, 4 s) until `seconds` have passed. `done(nil)` once connected,
    /// else what's wrong. The app's own retry may run alongside: `connect()` does nothing
    /// while an attempt is under way.
    static func connect(_ r: Remote, within seconds: Double, _ done: @escaping @MainActor (String?) -> Void) {
        if r.status == .connected { return done(nil) }
        if r.status.isFailure { r.connect() }   // failed some time ago: try now, not after a retry delay
        let delays: [Duration] = [.milliseconds(300), .seconds(1), .seconds(2), .seconds(4)]
        var retries = 0
        var failedAt: ContinuousClock.Instant?
        var lastError: ProtocolError?
        poll(for: seconds, until: {
            switch r.status {
            case .connected, .unpaired, .failed(.localNetworkDenied):
                return true   // nothing more to wait for
            case .failed(let e):
                lastError = e
                guard let at = failedAt else {
                    failedAt = .now
                    return false
                }
                if ContinuousClock.now - at >= delays[min(retries, delays.count - 1)] {
                    retries += 1
                    failedAt = nil
                    r.connect()
                }
            case .idle:
                r.connect()
            case .connecting:
                failedAt = nil
            case .waitingForPIN, .pairing:
                break
            }
            return false
        }, then: { _ in
            switch r.status {
            case .connected: done(nil)
            // Out of time mid-attempt: the last attempt's reason says more than "connecting".
            case .connecting: done((lastError ?? .timeout).description)
            default: done(describe(r.status))
            }
        })
    }

    // MARK: - Describing things

    /// The `status` report, a line per fact.
    static func status(_ r: Remote) -> [String] {
        ["\(r.device.name): \(describe(r.status))",
         "power: \(describe(r.power))",
         "now playing: \(r.nowPlaying.map(describe) ?? "nothing")",
         "text field: \(r.textSession.map { "focused, \"\($0.text)\"" } ?? "none")",
         "airplay link: \(r.muteAvailable ? "up" : "down")",
         "controls: \(r.controlsKnown ? (controls(r).isEmpty ? "none" : controls(r).joined(separator: " ")) : "unknown")"]
    }

    static func statusJSON(_ r: Remote) -> JSON {
        ["tv": .string(r.device.name),
         "connection": .string(describe(r.status)),
         "power": .string(describe(r.power)),
         "now_playing": r.nowPlaying.map(json) ?? nil,
         "text_field": r.textSession.map { ["text": .string($0.text)] } ?? nil,
         "airplay_link": .bool(r.muteAvailable),
         "controls": r.controlsKnown ? .array(controls(r).map(JSON.string)) : nil]
    }

    /// What the TV says the current app takes, by name.
    static func controls(_ r: Remote) -> [String] {
        let names: [(MediaControls, String)] = [(.play, "play"), (.pause, "pause"), (.next, "next"), (.previous, "previous"),
                                                (.volume, "volume"), (.skipForward, "skip_forward"), (.skipBackward, "skip_backward")]
        return names.filter { r.controls.contains($0.0) }.map(\.1)
    }

    public static func describe(_ s: Remote.Status) -> String {
        switch s {
        case .idle: "not connected"
        case .connecting: "connecting"
        case .waitingForPIN: "waiting for the PIN"
        case .pairing: "pairing"
        case .connected: "connected"
        case .failed(let e): e.description
        case .unpaired: "the Apple TV forgot this pairing; pair again (tvctl pair)"
        }
    }

    static func describe(_ p: PowerState) -> String {
        switch p {
        case .awake: "awake"
        case .asleep: "asleep"
        case .unknown: "unknown"
        }
    }

    static func state(_ np: NowPlaying) -> String {
        if np.isPlaying { return "playing" }
        switch np.state {
        case 1, 2: return "paused"
        case 3: return "stopped"
        case 4: return "interrupted"
        case 5: return "seeking"
        default: return "unknown"
        }
    }

    public static func describe(_ np: NowPlaying) -> String {
        let title = [np.title, np.subtitle].compactMap { $0 }.joined(separator: " — ")
        let pos = NowPlaying.clock(np.position())
        let len = np.duration.map { " / " + NowPlaying.clock($0) } ?? " (live)"
        let subs = np.hasCaptions ? (np.captionsEnabled ? ", subtitles on" : ", subtitles off") : ""
        return "\(title.isEmpty ? "?" : title)  \(pos)\(len)  \(state(np))\(subs)"
    }

    static func json(_ np: NowPlaying) -> JSON {
        ["title": .optional(np.title),
         "subtitle": .optional(np.subtitle),
         "app": .optional(np.bundleID),
         "state": .string(state(np)),
         "position": .seconds(np.position()),
         "duration": .seconds(np.duration),
         "captions": np.hasCaptions ? .bool(np.captionsEnabled) : nil]
    }

    static func json(_ app: TVApp) -> JSON {
        ["name": .string(app.name), "bundle_id": .string(app.bundleID)]
    }

    static func json(_ item: UpNextItem, number: Int) -> JSON {
        ["number": .int(number),
         "title": .string(item.title),
         "subtitle": .optional(item.subtitle),
         "service": .optional(item.service),
         "reason": .optional(item.reason),
         "progress": item.progress.map { .number(($0 * 100).rounded() / 100) } ?? nil,
         "url": .optional(item.actionURL)]
    }

    /// "754", "12:34", "1:02:03" → seconds.
    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? false }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}
