import AppKit
import RemoteCore

/// `tvctl` commands that reach the app (see ControlServer). The ones about the app itself
/// are here: its window, and which Apple TV it controls. Everything else acts on the TV
/// and runs on the app's session through `TVCommand`, the same code tvctl runs by itself
/// when the app isn't running. A reply is what tvctl prints, plus its exit status.
@MainActor
extension AppDelegate {
    func command(_ argv: [String], reply: @escaping @MainActor (String, Int32) -> Void) {
        let inv = TVCommand.Invocation(argv)
        let rest = inv.args
        let finish: @MainActor (TVCommand.Result) -> Void = { reply($0.rendered(json: inv.json), $0.code) }

        switch inv.command ?? "" {
        case "reload":   // tvctl pair changed the pairings
            store = CredentialStore()
            if let r = remote, let creds = store.credentials(for: r.device.name) {
                if creds != r.credentials { use(r.device.name, creds) }
            } else if let name = store.last, let creds = store.credentials(for: name) {
                use(name, creds)
            }
            return finish(.done())
        case "show":
            show()
            return finish(.done())
        case "hide":
            hide()
            return finish(.done())
        case "sidebar":
            guard rest.count <= 1 else { return finish(.misused("sidebar takes one of open, close, upnext, apps", "sidebar")) }
            switch rest.first {
            case nil: setSidebar(!sidebarOpen, animate: true)
            case "open", "on": setSidebar(true, animate: true)
            case "close", "off": setSidebar(false, animate: true)
            case "upnext", "apps":
                setSidebar(true, animate: true)
                sidebarTab(rest.first == "apps" ? 1 : 0)
            default: return finish(.misused("sidebar takes one of open, close, upnext, apps", "sidebar"))
            }
            return finish(.done("", ["open": .bool(sidebarOpen)]))
        case "snapshot":
            // tvctl debug snapshot: window content to PNG (Liquid Glass doesn't render
            // offscreen). Options: dark | light (appearance for this shot), controls (hide
            // the pairing panel).
            guard let path = rest.first else { return finish(.misused("usage: tvctl debug snapshot <file.png> [dark|light] [controls]")) }
            let saved = window.appearance
            if rest.contains("dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if rest.contains("light") { window.appearance = NSAppearance(named: .aqua) }
            if rest.contains("controls") { view.showsPairing = false }
            snapshot(to: (path as NSString).expandingTildeInPath)
            window.appearance = saved
            return finish(.done(path, ["file": .string(path)]))
        case "use", "forget":
            // The TV menu's two actions. tvctl has checked the name against the pairings.
            store = CredentialStore()
            guard let name = rest.first.flatMap(store.name(matching:)), let creds = store.credentials(for: name) else {
                return finish(.failed("\"\(rest.first ?? "")\" isn't a paired Apple TV (tvctl tvs lists them)"))
            }
            if inv.command == "forget" {
                if name == remote?.device.name { forgetCurrent() } else { try? store.remove(name) }
                return finish(.done("forgot \(name)", ["tv": .string(name)]))
            }
            try? store.touch(name)
            if name != remote?.device.name { use(name, creds) }
            if !window.isVisible || NSApp.isHidden { armIdle() }
            return finish(.done("using \(name)", ["tv": .string(name)]))
        default:
            break
        }

        guard let r = remote else { return finish(.failed("no Apple TV is paired yet: tvctl scan, then tvctl pair <tv>")) }
        // --tv for a TV that isn't this one: its connection is free, tvctl uses it itself.
        if let tv = inv.tv, tv != r.device.name { return reply("", TVCommand.otherTV) }
        if !window.isVisible || NSApp.isHidden { armIdle() }   // a hidden app's session still times out
        TVCommand.run(inv, on: r, reply: reply)
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
