import Testing
@testable import RemoteCore

// tvctl's command line as text: how arguments are read, what the help says, the JSON.

private typealias Invocation = TVCommand.Invocation
private typealias Help = TVCommand.Help

@Test func optionsAreReadAnywhereBeforeTheDoubleDash() {
    var inv = Invocation(["--json", "press", "up", "--tv", "Bedroom", "down"])
    #expect(inv.json && inv.tv == "Bedroom" && inv.command == "press" && inv.args == ["up", "down"])
    inv = Invocation(["type", "--", "--json", "-v"])
    #expect(!inv.json && !inv.verbose && inv.command == "type" && inv.args == ["--json", "-v"])
    inv = Invocation(["--tv=Living Room", "skip", "-10"])
    #expect(inv.tv == "Living Room" && inv.command == "skip" && inv.args == ["-10"])   // a negative number is an argument
    #expect(Invocation(["pause", "--tv"]).problem != nil)
    #expect(Invocation([]).command == nil)
}

@Test func otherNamesLeadToTheSameCommands() {
    #expect(Invocation(["np"]).command == "playing")
    #expect(Invocation(["wake"]) == Invocation(["power", "on"]))
    #expect(Invocation(["sleep"]) == Invocation(["power", "off"]))
    #expect(Invocation(["subtitles", "on"]) == Invocation(["captions", "on"]))
}

@Test func helpIsAskedForInThreeWays() {
    for argv in [["help", "press"], ["press", "--help"], ["-h", "press"]] {
        let inv = Invocation(argv)
        #expect(inv.help && inv.command == "press")
    }
    #expect(Invocation(["help"]).help && Invocation(["help"]).command == nil)
    #expect(Invocation(["help", "np"]).command == "playing")
}

@Test func theAppReadsTheSameCommandLine() {
    // What tvctl sends the app parses back to the same thing, whatever the arguments hold.
    for argv in [["--json", "--tv", "Bedroom", "type", "--", "--json", "x"], ["wake"], ["press", "up", "1", "down"], ["text", ""]] {
        var inv = Invocation(argv)
        inv.direct = false
        #expect(Invocation(inv.wire) == inv)
    }
}

@Test func jsonIsOneLineInTheOrderWritten() {
    let v: JSON = ["ok": true, "title": "Say \"hi\"\n\tnow", "n": 3, "pos": .seconds(12.3456), "whole": .seconds(60),
                   "none": nil, "list": [1, "two", false], "bad": .number(.infinity), "é": "ü ✓", "ctl": "\u{01}"]
    #expect(v.text == #"{"ok":true,"title":"Say \"hi\"\n\tnow","n":3,"pos":12.346,"whole":60,"none":null,"#
            + #""list":[1,"two",false],"bad":null,"é":"ü ✓","ctl":"\u0001"}"#)
    #expect(v["n"] == .int(3) && v["missing"] == nil)
}

@Test func resultsRenderAsTextOrJSON() {
    #expect(TVCommand.Result.done("hello", ["a": 1]).rendered(json: false) == "hello")
    #expect(TVCommand.Result.done("hello", ["a": 1]).rendered(json: true) == #"{"ok":true,"a":1}"#)
    #expect(TVCommand.Result.done().rendered(json: true) == #"{"ok":true}"#)
    let failed = TVCommand.Result.failed("nothing is playing")
    #expect(failed.code == 1 && failed.rendered(json: true) == #"{"ok":false,"error":"nothing is playing"}"#)
    let misused = TVCommand.Result.misused("no button to press", "press")
    #expect(misused.code == 2)
    #expect(misused.text == "no button to press\nusage: tvctl press <button|seconds>...   (more: tvctl help press)")
}

@Test @MainActor func helpTheParserAndTheCommandListAgree() {
    let onTV: Set = ["press", "hold", "playing", "play", "pause", "playpause", "skip", "seek", "volume", "mute", "captions",
                     "type", "text", "apps", "launch", "upnext", "status", "power"]
    let elsewhere: Set = ["tvs", "use", "scan", "pair", "forget", "show", "hide", "sidebar"]   // tvctl itself, or the app
    #expect(Set(Help.entries.map(\.name)) == onTV.union(elsewhere))
    #expect(Help.entries.count == onTV.count + elsewhere.count)   // no name twice

    for e in Help.entries {
        // In the command list under its own name, with help of its own.
        let listed = ["\n  \(e.name) ", "\n  \(e.name)\n", "| \(e.name) ", "| \(e.name)\n"].contains { Help.overview.contains($0) }
        #expect(listed, "\(e.name) is missing from tvctl help")
        #expect(e.usage == e.name || e.usage.hasPrefix(e.name + " "))
        #expect(Help.text(for: e.name)?.hasPrefix("usage: tvctl \(e.usage)") == true)
        #expect(!e.summary.isEmpty && !e.detail.isEmpty)
        for example in e.examples { #expect(example.hasPrefix("tvctl ")) }
    }
    // The parser knows exactly the commands that act on the TV (it may still want arguments).
    for name in onTV.union(elsewhere) {
        var unknown = false
        if case .misuse(let r) = TVCommand.parse(name, []) { unknown = r.text.hasPrefix("unknown command") }
        #expect(unknown == elsewhere.contains(name), "\(name)")
    }
    // Every other name is for a real command and isn't one itself.
    for (alias, target) in Invocation.aliases {
        #expect(Help.entry(target.0) != nil && Help.entry(alias) == nil, "\(alias)")
    }
    // Every button named in the help can be pressed, and the other way around.
    #expect(Button.names.allSatisfy { Button.named($0) != nil })
    #expect(Button.names.allSatisfy { Help.entry("press")!.detail.contains($0) })
    // It all fits an 80-column terminal.
    let everything = [Help.overview, Help.debug] + Help.entries.compactMap { Help.text(for: $0.name) }
    for line in everything.joined(separator: "\n").split(separator: "\n") where line.count > 80 {
        Issue.record("wider than 80 columns: \(line)")
    }
    #expect(Help.text(for: "debug") == Help.debug && Help.text(for: "nonsense") == nil)
    #expect(Help.catalog["commands"] != nil)
}

@Test func unknownCommandsGetAHint() {
    #expect(Help.unknown("up") == "unknown command \"up\": to click a button, tvctl press up")
    #expect(Help.unknown("raw") == "unknown command \"raw\": the debug tool is tvctl debug raw")
    #expect(Help.unknown("pres") == "unknown command \"pres\": did you mean press? (tvctl help)")
    #expect(Help.unknown("stauts").contains("did you mean status?"))
    #expect(Help.unknown("frobnicate") == "unknown command \"frobnicate\" (tvctl help lists the commands)")
}

@Test func anAppIsFoundByIdOrName() {
    let apps = [TVApp(bundleID: "com.apple.TVWatchList", name: "TV"), TVApp(bundleID: "com.apple.TVShows", name: "TV Shows"),
                TVApp(bundleID: "com.netflix.Netflix", name: "Netflix"), TVApp(bundleID: "com.apple.TVMusic", name: "Music")]
    #expect(TVCommand.find("netflix", in: apps) == .one(apps[2]))
    #expect(TVCommand.find("COM.APPLE.TVMUSIC", in: apps) == .one(apps[3]))
    #expect(TVCommand.find("tv", in: apps) == .one(apps[0]))              // an exact name beats a longer one
    #expect(TVCommand.find("t", in: apps) == .several([apps[0], apps[1]]))
    #expect(TVCommand.find("flix", in: apps) == .one(apps[2]))            // part of one name
    #expect(TVCommand.find("hulu", in: apps) == .none)
    #expect(TVCommand.find("anything", in: []) == .none)
}

@Test @MainActor func positionsAreSecondsOrClockTimes() {
    #expect(TVCommand.seconds("754") == 754)
    #expect(TVCommand.seconds("12:34") == 754)
    #expect(TVCommand.seconds("1:02:03") == 3723)
    #expect(TVCommand.seconds("1:2:3:4") == nil)
    #expect(TVCommand.seconds("-5") == nil)
    #expect(TVCommand.seconds("1::3") == nil)
    #expect(TVCommand.seconds("abc") == nil)
}
