extension TVCommand {
    /// The words of tvctl: the command list (`overview`), every command's own help
    /// (`entries`), and what to say about a command that doesn't exist. Written for a
    /// person or an agent who has never seen tvctl: `tvctl help` must be enough to use it.
    ///
    /// Adding a command: an entry here, a line in `overview`, and its case in
    /// `TVCommand.parse` (or, for one that doesn't act on the TV, in tvctl / the app). A
    /// test checks the three agree.
    public enum Help {
        public struct Entry: Sendable {
            public let name: String
            public let group: String
            /// The command and its arguments, as typed after "tvctl".
            public let usage: String
            public let summary: String
            public let detail: String
            public var examples: [String] = []

            /// Other names it answers to.
            public var aliases: [String] {
                Invocation.aliases.filter { $0.value.0 == name && $0.value.1.isEmpty }.map(\.key).sorted()
            }
        }

        public static func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

        public static let overview = """
        tvctl — control an Apple TV from the command line (part of RemoteTV)

        Usage: tvctl [options] <command> [arguments]

        Remote
          press <button|seconds>...  Click buttons in order; a number pauses that long
          hold <button> [seconds]    Hold a button: long-press menus, fast scrolling

        Playback
          playing                    What's playing: title, position, state
          play | pause | playpause   Resume, pause, or switch between the two
          skip <seconds>             Skip forward, or back with a negative number
          seek <position>            Jump to a position: 754, 12:34 or 1:02:03
          volume up|down [steps]     Change the volume
          mute                       Toggle mute
          captions [on|off]          Toggle subtitles, or turn them on or off

        Text
          type <text>                Type into the text field focused on the TV
          text [<text>]              Show that field's text, or replace it

        Apps
          apps                       List the apps on the Apple TV
          launch <app|url>           Open an app by name or bundle id, or a link
          upnext [<number>]          List Up Next, or play one of its items

        Apple TV
          status                     Connection, power, what's playing
          power [on|off|toggle]      Show whether the TV is awake, or wake / sleep it
          tvs                        List paired Apple TVs (* marks the one in use)
          use <tv>                   Switch to another paired Apple TV
          scan [seconds]             Find Apple TVs on the network
          pair <tv>                  Pair with an Apple TV; asks for the PIN it shows
          forget <tv>                Remove an Apple TV's pairing

        RemoteTV window
          show | hide                Show or hide the RemoteTV window
          sidebar [open|close|upnext|apps]
                                     Open or close the sidebar, or open it on a tab

        Options
          --tv <name>                Act on this paired Apple TV, not the one in use
          --json                     Print the result as one JSON object
          -h, --help                 Help for tvctl, or for the command given
          --version                  Print the version

        Run "tvctl help <command>" for details and examples.

        tvctl works with or without the RemoteTV app running. It exits with 0 when the
        command worked, 1 when it failed (the message says why) and 2 when it wasn't
        understood. With --json it prints {"ok":true,...} or {"ok":false,"error":"..."}.
        """

        public static let debug = """
        tvctl debug <tool> — tools for working on RemoteTV's protocol code

          raw <request> [key=value...]   Send any Companion request, print the reply
          event <name> [key=value...]    Send a Companion event (there is no reply)
          listen <seconds> [event...] [+request...] [!button...]
                                         Print what the TV sends: register the events,
                                         send the +requests, press the !buttons
          airplay                        Open the AirPlay link alone, print its messages
          mrp [seconds]                  MediaRemote over the AirPlay link: now playing
          mrp mute | mrp seek <seconds>  ... and its mute key and absolute seek
          snapshot <file.png> [dark|light] [controls]
                                         Save the RemoteTV window as a PNG

        Options
          --direct       Use tvctl's own connection even while RemoteTV is running, and
                         print the connect timings. The TV keeps one connection per
                         pairing: the app loses its for a moment and reconnects.
          -v, --verbose  --direct, and print every message sent and received

        Values in key=value are integers, decimals (with a "."), true/false, or text.
        raw, snapshot and every normal command go through the app when it is running;
        the other tools always use their own connection (quit the app first).
        """

        public static let entries: [Entry] = [
            Entry(name: "press", group: "remote", usage: "press <button|seconds>...",
                  summary: "Click buttons in order; a number pauses that long",
                  detail: """
                  Clicks each button in turn, like tapping the Siri Remote. A number waits that
                  many seconds before going on, for a screen that needs a moment to load (up to
                  10 seconds in all).

                  Buttons: up down left right select menu home playpause volumeup volumedown
                           siri screensaver guide pageup pagedown channelup channeldown
                  Also:    ok (select), back (menu), tv (home)
                  """,
                  examples: ["tvctl press down down select", "tvctl press home 1.5 right select"]),
            Entry(name: "hold", group: "remote", usage: "hold <button> [seconds]",
                  summary: "Hold a button: long-press menus, fast scrolling",
                  detail: """
                  Holds a button down (for 1 second unless told otherwise, 10 at most) and lets
                  go. Holding select opens an item's menu, holding home opens Control Center,
                  holding a direction scrolls. Buttons are those of "tvctl help press".
                  """,
                  examples: ["tvctl hold select", "tvctl hold down 3"]),

            Entry(name: "playing", group: "playback", usage: "playing",
                  summary: "What's playing: title, position, state",
                  detail: """
                  Prints the title, how far in it is and how long, and whether it is playing
                  or paused; or "nothing is playing".

                  With --json: now_playing is null or {title, subtitle, app, state, position,
                  duration, captions}. position and duration are seconds; duration is null for
                  live video; captions is true, false, or null when the app doesn't say.
                  """,
                  examples: ["tvctl playing", "tvctl --json playing"]),
            Entry(name: "play", group: "playback", usage: "play",
                  summary: "Resume playback",
                  detail: """
                  Resumes what is paused. Does nothing when it is already playing, so it is safe
                  to repeat. When nothing is playing it presses Play, which starts whatever is
                  selected on screen.

                  With --json: changed tells whether anything was sent.
                  """),
            Entry(name: "pause", group: "playback", usage: "pause",
                  summary: "Pause playback",
                  detail: """
                  Pauses what is playing. Does nothing when it is already paused or nothing is
                  playing, so it is safe to repeat.

                  With --json: changed tells whether anything was sent.
                  """),
            Entry(name: "playpause", group: "playback", usage: "playpause",
                  summary: "Press Play/Pause",
                  detail: """
                  Presses the remote's Play/Pause button: pauses when playing, resumes when
                  paused. To ask for one of the two, use "tvctl play" or "tvctl pause".
                  """),
            Entry(name: "skip", group: "playback", usage: "skip <seconds>",
                  summary: "Skip forward, or back with a negative number",
                  detail: "Moves playback by that many seconds: forward, or back when negative.",
                  examples: ["tvctl skip 30", "tvctl skip -10"]),
            Entry(name: "seek", group: "playback", usage: "seek <position>",
                  summary: "Jump to a position: 754, 12:34 or 1:02:03",
                  detail: """
                  Jumps to a position counted from the start: seconds (754), minutes and
                  seconds (12:34), or hours too (1:02:03). Fails when nothing is playing.
                  """,
                  examples: ["tvctl seek 12:34", "tvctl seek 0"]),
            Entry(name: "volume", group: "playback", usage: "volume up|down [steps]",
                  summary: "Change the volume",
                  detail: """
                  Presses volume up or down, once or the number of steps given (20 at most).
                  The volume only changes when the Apple TV controls the TV's or receiver's
                  volume (HDMI-CEC); if it doesn't, the press is ignored without an error.
                  """,
                  examples: ["tvctl volume up", "tvctl volume down 3"]),
            Entry(name: "mute", group: "playback", usage: "mute",
                  summary: "Toggle mute",
                  detail: """
                  Mutes or unmutes. The Apple TV doesn't report whether the sound is muted, so
                  there is no "on" or "off". Needs the AirPlay link ("tvctl status" shows it).
                  """),
            Entry(name: "captions", group: "playback", usage: "captions [on|off]",
                  summary: "Toggle subtitles, or turn them on or off",
                  detail: """
                  With no argument, toggles subtitles for what is playing. With on or off it
                  acts only if needed, which works in apps that report their subtitles (the TV
                  app does); in the others it fails and only the toggle is available.

                  With --json (on/off): changed tells whether anything was sent.
                  """,
                  examples: ["tvctl captions", "tvctl captions on"]),

            Entry(name: "type", group: "text", usage: "type <text>",
                  summary: "Type into the text field focused on the TV",
                  detail: """
                  Types at the cursor of the text field that has focus on the TV, such as a
                  search box. Fails when no text field has focus. Several words are joined with
                  spaces; put "--" before text that starts with dashes.
                  """,
                  examples: ["tvctl type severance", "tvctl type -- --help"]),
            Entry(name: "text", group: "text", usage: "text [<text>]",
                  summary: "Show that field's text, or replace it",
                  detail: """
                  With no argument, prints what the focused text field holds (some apps, like
                  YouTube, don't report it: the line is empty). With an argument, replaces the
                  field's contents; an empty string clears it. Fails when no field has focus.

                  With --json (no argument): text.
                  """,
                  examples: ["tvctl text", "tvctl text \"the bear\"", "tvctl text \"\""]),

            Entry(name: "apps", group: "apps", usage: "apps",
                  summary: "List the apps on the Apple TV",
                  detail: """
                  Lists the installed apps by name, each with its bundle id.

                  With --json: apps is a list of {name, bundle_id}.
                  """),
            Entry(name: "launch", group: "apps", usage: "launch <app|url>",
                  summary: "Open an app by name or bundle id, or a link",
                  detail: """
                  Opens an app, named as "tvctl apps" lists it or by bundle id. Case doesn't
                  matter and a name can be shortened while it still means one app. Anything
                  with "://" is opened as a link in the app that handles it.

                  With --json: launched is {name, bundle_id} or {url}.
                  """,
                  examples: ["tvctl launch netflix", "tvctl launch com.apple.TVMusic", "tvctl launch \"https://tv.apple.com/show/...\""]),
            Entry(name: "upnext", group: "apps", usage: "upnext [<number>]",
                  summary: "List Up Next, or play one of its items",
                  detail: """
                  Lists the Apple TV's Up Next (continue watching), numbered. With a number,
                  plays that item in its app.

                  With --json: items is a list of {number, title, subtitle, service, reason,
                  progress, url}; progress is 0 to 1, or null.
                  """,
                  examples: ["tvctl upnext", "tvctl upnext 2"]),

            Entry(name: "status", group: "apple tv", usage: "status",
                  summary: "Connection, power, what's playing",
                  detail: """
                  Shows whether the Apple TV can be reached and is awake, what is playing, the
                  focused text field, and what the current app accepts. Fails, saying why,
                  when the TV can't be reached.

                  With --json: {tv, connection, power, now_playing, text_field, airplay_link,
                  controls}; controls is a list of names, or null while unknown.
                  """),
            Entry(name: "power", group: "apple tv", usage: "power [on|off|toggle]",
                  summary: "Show whether the TV is awake, or wake / sleep it",
                  detail: """
                  With no argument, prints awake or asleep. "on" wakes the Apple TV and "off"
                  puts it to sleep (taking the TV set with it over HDMI-CEC); both are safe to
                  repeat. "toggle" is the remote's power button.

                  "tvctl wake" and "tvctl sleep" are the same as "power on" and "power off".
                  With --json (no argument): power is "awake", "asleep" or "unknown".
                  """,
                  examples: ["tvctl power", "tvctl power off"]),
            Entry(name: "tvs", group: "apple tv", usage: "tvs",
                  summary: "List paired Apple TVs (* marks the one in use)",
                  detail: """
                  Lists the Apple TVs paired with this Mac. The one marked * is the one that
                  commands act on: the last one used, here or in the RemoteTV window.

                  With --json: tvs is a list of {name, in_use}.
                  """),
            Entry(name: "use", group: "apple tv", usage: "use <tv>",
                  summary: "Switch to another paired Apple TV",
                  detail: """
                  Makes another paired Apple TV the one that commands act on, in the RemoteTV
                  window too. To send one command to another TV without switching, give that
                  command --tv <name> instead.
                  """,
                  examples: ["tvctl use Bedroom", "tvctl --tv Bedroom pause"]),
            Entry(name: "scan", group: "apple tv", usage: "scan [seconds]",
                  summary: "Find Apple TVs on the network",
                  detail: """
                  Looks for Apple TVs on the local network for 2 seconds (or as long as given)
                  and lists each one's name, model, and whether it is paired.

                  With --json: tvs is a list of {name, model, paired}.
                  """),
            Entry(name: "pair", group: "apple tv", usage: "pair <tv>",
                  summary: "Pair with an Apple TV; asks for the PIN it shows",
                  detail: """
                  Pairs with an Apple TV, named as "tvctl scan" shows it. The TV displays a
                  4-digit PIN and tvctl asks for it, so someone has to be able to see the
                  screen. The new pairing becomes the TV in use; pairing a TV again replaces
                  its old pairing.
                  """,
                  examples: ["tvctl pair \"Living Room\""]),
            Entry(name: "forget", group: "apple tv", usage: "forget <tv>",
                  summary: "Remove an Apple TV's pairing",
                  detail: "Removes this Mac's pairing with an Apple TV. Pairing again needs the PIN from\nits screen."),

            Entry(name: "show", group: "window", usage: "show",
                  summary: "Show the RemoteTV window",
                  detail: "Shows the RemoteTV window and brings it to the front, starting the app if it\nisn't running."),
            Entry(name: "hide", group: "window", usage: "hide",
                  summary: "Hide the RemoteTV window",
                  detail: "Hides the RemoteTV window. The app keeps running; \"tvctl show\" brings it back."),
            Entry(name: "sidebar", group: "window", usage: "sidebar [open|close|upnext|apps]",
                  summary: "Open or close the sidebar, or open it on a tab",
                  detail: """
                  With no argument, opens the window's sidebar or closes it if it is open.
                  "upnext" and "apps" open it on that tab. Starts the app if it isn't running.
                  """),
        ]

        /// Help for a command (or "debug"); nil for something that isn't one.
        public static func text(for topic: String) -> String? {
            if topic == "debug" { return debug }
            guard let e = entry(topic) else { return nil }
            var out = "usage: tvctl \(e.usage)\n\n\(e.detail)"
            if !e.aliases.isEmpty { out += "\n\nAlso called: \(e.aliases.joined(separator: ", "))" }
            if !e.examples.isEmpty { out += "\n\nExamples:\n" + e.examples.map { "  " + $0 }.joined(separator: "\n") }
            return out
        }

        /// The command list for `tvctl help --json`.
        public static var catalog: JSON {
            ["commands": .array(entries.map { e in
                ["name": .string(e.name), "group": .string(e.group), "usage": .string("tvctl " + e.usage),
                 "summary": .string(e.summary), "aliases": .array(e.aliases.map(JSON.string))]
            }),
             "options": [["name": "--tv <name>", "summary": "Act on this paired Apple TV, not the one in use"],
                         ["name": "--json", "summary": "Print the result as one JSON object: {\"ok\":true,...} or {\"ok\":false,\"error\":\"...\"}"],
                         ["name": "-h, --help", "summary": "Help for tvctl, or for the command given"],
                         ["name": "--version", "summary": "Print the version"]],
             "exit_status": ["0": "the command worked", "1": "it failed; the message says why", "2": "it wasn't understood"]]
        }

        static let debugTools = ["raw", "event", "listen", "airplay", "mrp", "snapshot"]

        /// What to say about a command that doesn't exist: the likely fix when there is one.
        public static func unknown(_ cmd: String) -> String {
            let said = "unknown command \"\(cmd)\""
            if Button.named(cmd) != nil { return "\(said): to click a button, tvctl press \(cmd)" }
            if debugTools.contains(cmd) { return "\(said): the debug tool is tvctl debug \(cmd)" }
            let names = entries.map(\.name) + Invocation.aliases.keys + ["help", "debug"]
            let near = names.map { ($0, distance(cmd.lowercased(), $0)) }.filter { $0.1 <= 2 && $0.1 < $0.0.count }.min { $0.1 < $1.1 }
            if let near { return "\(said): did you mean \(near.0)? (tvctl help)" }
            return "\(said) (tvctl help lists the commands)"
        }

        /// Edit distance (insert, delete, replace), for "did you mean".
        static func distance(_ a: String, _ b: String) -> Int {
            let a = Array(a), b = Array(b)
            var row = Array(0...b.count)
            for i in 0..<a.count {
                var previous = row[0]
                row[0] = i + 1
                for j in 0..<b.count {
                    let keep = row[j + 1]
                    row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (a[i] == b[j] ? 0 : 1))
                    previous = keep
                }
            }
            return row[b.count]
        }
    }
}
