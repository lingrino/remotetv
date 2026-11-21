import AppKit
import RemoteCore

/// Temporary shell: discovers Apple TVs (triggers the Local Network prompt) and installs
/// the media-key tap (Accessibility prompt), so the grants exist before the remote does.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "")
    private var browser: Browser?
    private let mediaKeys = MediaKeys()
    private var devices: [Device] = []
    private var lastKey = "none"

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RemoteTV"
        window.isReleasedWhenClosed = false
        status.frame = NSRect(x: 20, y: 20, width: 260, height: 180)
        status.font = .systemFont(ofSize: 13)
        window.contentView?.addSubview(status)
        window.center()
        window.makeKeyAndOrderFront(nil)

        browser = Browser { [weak self] in self?.devices = $0; self?.render() }
        browser?.start()

        mediaKeys.handler = { [weak self] key, down, rep in
            self?.lastKey = "\(key) \(down ? "down" : "up")\(rep ? " repeat" : "")"
            self?.render()
        }
        if !MediaKeys.trusted { MediaKeys.requestTrust() }
        mediaKeys.enable()
        render()
    }

    func applicationDidBecomeActive(_ note: Notification) {
        mediaKeys.enable()
        render()
    }

    func applicationDidResignActive(_ note: Notification) {
        mediaKeys.disable()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return false
    }

    private func render() {
        let tvs = devices.isEmpty ? "searching…" : devices.map { "\($0.name) (\($0.model))" }.joined(separator: "\n")
        status.stringValue = """
        Apple TVs:
        \(tvs)

        Accessibility: \(MediaKeys.trusted ? "granted" : "not granted")
        Media key tap: \(mediaKeys.isEnabled ? "on" : "off")
        Last media key: \(lastKey)
        """
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit RemoteTV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
    }
}
