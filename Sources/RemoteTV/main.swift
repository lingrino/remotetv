import AppKit

MainActor.assumeIsolated { Launch.mark("main") }
// The delegate first: its init starts connecting to the Apple TV while AppKit loads.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
