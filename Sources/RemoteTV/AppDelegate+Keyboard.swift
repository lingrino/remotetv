import AppKit
import RemoteCore

/// The keyboard and the Mac's media keys as remote buttons.
@MainActor
extension AppDelegate {
    // MARK: - Keyboard

    /// Remote keys while the window is key. Arrows/Return/Delete/Space/T are held like the
    /// Siri Remote's buttons (down on key down, up on key up); [ ] skip; - = volume.
    func key(_ e: NSEvent, down: Bool) -> Bool {
        guard let r = remote, !view.showsPairing else { return false }
        // ⌘-keys are menu shortcuts; but a key-up always releases what it held.
        if down && e.modifierFlags.contains(.command) { return false }
        let code = e.keyCode
        if code == 48, down, !view.text.isHidden {   // Tab: back into the TV's text field
            window.makeFirstResponder(view.text.field)
            return true
        }
        let held: Button? = switch code {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .select           // Return, keypad Enter
        case 51, 53, 117: .menu        // Delete, Escape, forward delete
        case 49: .playPause            // Space
        case 17, 4: .home              // T, H
        default: nil
        }
        if let b = held {
            if down {
                if !e.isARepeat && heldKeys[code] == nil {
                    heldKeys[code] = b
                    r.button(b, down: true)
                }
            } else if let b = heldKeys.removeValue(forKey: code) {
                r.button(b, down: false)
            }
            return true
        }
        guard down else { return code == 33 || code == 30 || code == 27 || code == 24 }
        switch code {
        case 33: if !e.isARepeat { r.skip(-10) }   // [
        case 30: if !e.isARepeat { r.skip(10) }    // ]
        case 27: r.press(.volumeDown)               // -
        case 24: r.press(.volumeUp)                 // =
        default: return false
        }
        return true
    }

    /// Lets go of every held key and click (focus moved away mid-press).
    func releaseAll() {
        for (_, b) in heldKeys { remote?.button(b, down: false) }
        heldKeys.removeAll()
        view.pad.cancel()
    }

    /// Volume/play keys while RemoteTV is active. Returns false for keys it leaves to
    /// macOS (mute).
    func mediaKey(_ key: MediaKeys.Key, down: Bool, repeat rep: Bool) -> Bool {
        // Not connected (TV away or asleep, no pairing): the keys are the Mac's again.
        guard let r = remote, r.status == .connected || r.status == .connecting else { return false }
        switch key {
        case .volumeUp: if down { r.press(.volumeUp) }
        case .volumeDown: if down { r.press(.volumeDown) }
        case .playPause: if down && !rep { r.press(.playPause) }
        case .next, .fast: if down && !rep { r.skip(10) }
        case .previous, .rewind: if down && !rep { r.skip(-10) }
        case .mute: return false
        }
        return true
    }
}
