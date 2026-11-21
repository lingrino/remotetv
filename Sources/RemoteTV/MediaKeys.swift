import AppKit

/// The keyboard's media keys (volume, mute, play/pause, next/previous) while RemoteTV is
/// the active app. macOS handles these keys itself (Mac volume, Music), so the only way to
/// take them is an active session event tap, which needs the Accessibility grant. The tap
/// exists only while the app is active, so the keys behave normally everywhere else.
@MainActor
final class MediaKeys {
    enum Key: Int {
        case volumeUp = 0      // NX_KEYTYPE_SOUND_UP
        case volumeDown = 1    // NX_KEYTYPE_SOUND_DOWN
        case mute = 7          // NX_KEYTYPE_MUTE
        case playPause = 16    // NX_KEYTYPE_PLAY
        case next = 17         // NX_KEYTYPE_NEXT
        case previous = 18     // NX_KEYTYPE_PREVIOUS
        case fast = 19         // NX_KEYTYPE_FAST
        case rewind = 20       // NX_KEYTYPE_REWIND
    }

    /// (key, isDown, isRepeat). Called on the main thread from the tap.
    var handler: ((Key, Bool, Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if the grant is missing.
    static func requestTrust() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Installs (or re-enables) the tap. Returns false without the Accessibility grant.
    @discardableResult
    func enable() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        guard MediaKeys.trusted else { return false }
        let mask = CGEventMask(1) << MediaKeys.systemDefined
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            MediaKeys.tapped(type, event)
        }, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        MediaKeys.current = self
        return true
    }

    func disable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    // MARK: - Tap

    private nonisolated static let systemDefined: CGEventMask = 14   // NX_SYSDEFINED
    private nonisolated static let auxControlButtons: Int16 = 8      // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static var current: MediaKeys?

    /// Runs on the main thread (the tap's run loop source is on the main run loop) for every
    /// system-defined event while the app is active; everything else passes untouched.
    private nonisolated static func tapped(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let tap = current?.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == UInt32(systemDefined),
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == auxControlButtons
        else { return Unmanaged.passUnretained(event) }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let flags = data & 0xFFFF
        guard let key = Key(rawValue: code) else { return Unmanaged.passUnretained(event) }
        let down = (flags & 0xFF00) >> 8 == 0xA   // 0xA down, 0xB up
        let rep = flags & 1 == 1
        MainActor.assumeIsolated { current?.handler?(key, down, rep) }
        return nil
    }
}
