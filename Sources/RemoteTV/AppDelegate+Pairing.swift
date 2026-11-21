import AppKit
import RemoteCore

/// The TV menu, Bonjour browsing, and the pairing flow (pick a TV, type its PIN).
@MainActor
extension AppDelegate {
    // MARK: - Device menu and browsing

    func browse() {
        guard browser == nil else { return }
        let b = Browser { [weak self] found in
            guard let self else { return }
            self.devices = found
            if self.view.showsPairing && self.pairer == nil { self.showDeviceList() }
        }
        browser = b
        b.start()
    }

    @objc func showDeviceMenu() {
        let menu = NSMenu()
        let current = remote?.device.name
        var names = store.entries.map(\.name)
        for d in devices where !names.contains(d.name) { names.append(d.name) }
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(menuPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == current ? .on : .off
            let lost = name == current && remote?.status == .unpaired
            if store.credentials(for: name) == nil || lost { item.title = "\(name) — Pair Again…" }
            menu.addItem(item)
        }
        if names.isEmpty {
            let item = NSMenuItem(title: "Looking for Apple TVs…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pairItem = NSMenuItem(title: "Pair Another Apple TV…", action: #selector(startPairingAction), keyEquivalent: "")
        pairItem.target = self
        menu.addItem(pairItem)
        if let current, store.credentials(for: current) != nil {
            let forget = NSMenuItem(title: "Forget “\(current)”", action: #selector(forgetCurrent), keyEquivalent: "")
            forget.target = self
            menu.addItem(forget)
        }
        let b = view.title
        menu.popUp(positioning: nil, at: NSPoint(x: b.bounds.midX - 60, y: b.bounds.maxY + 4), in: b)
    }

    @objc func menuPick(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        if name == remote?.device.name, remote?.status == .unpaired { return pair(name) }
        if let creds = store.credentials(for: name) { use(name, creds) } else { pair(name) }
    }

    @objc func forgetCurrent() {
        guard let name = remote?.device.name else { return }
        try? store.remove(name)
        remote?.disconnect()
        remote = nil
        if let next = store.last, let creds = store.credentials(for: next) { use(next, creds) } else { startPairing() }
    }

    // MARK: - Pairing

    @objc func startPairingAction() { startPairing() }

    func startPairing() {
        pairer?.disconnect()
        pairer = nil
        view.showsPairing = true
        updateHeader()
        showDeviceList()
        browse()
    }

    func showDeviceList() {
        view.pairing.showDevices(devices.map(\.name), paired: Set(store.entries.map(\.name)))
    }

    func pair(_ name: String) {
        pairer?.disconnect()   // a previous attempt (its PIN may still be on the TV)
        view.showsPairing = true
        updateHeader()
        let p = Remote(device: device(named: name), credentials: nil)
        p.onStatus = { [weak self, weak p] s in
            guard let self, let p, p === self.pairer else { return }
            self.pairingStatus(p, s)
        }
        p.onPaired = { [weak self] creds in
            guard let self else { return }
            do { try self.store.save(name, creds) } catch {
                AppDelegate.log.error("saving pairing: \(error.localizedDescription, privacy: .public)")
            }
        }
        pairer = p
        view.pairing.showWorking("Connecting to “\(name)”…")
        view.pairing.heading.stringValue = "Pairing"
        p.pair()
    }

    func pairingStatus(_ p: Remote, _ s: Remote.Status) {
        // Paired: from here on this session is the remote (connected, or failing to
        // connect, which the normal retry handles).
        if p.credentials != nil, s == .connected || s.isFailure {
            pairer = nil
            remote?.disconnect()
            remote = p
            adopt(p)
            showRemote(p)
            statusChanged(s)
            return
        }
        switch s {
        case .waitingForPIN:
            view.pairing.showPIN(for: p.device.name, error: nil)
        case .pairing:
            view.pairing.showWorking("Pairing…")
        case .failed(let e):
            let text = e.description
            view.pairing.showPIN(for: p.device.name, error: text.prefix(1).uppercased() + text.dropFirst())
            view.pairing.pin.isEnabled = false
            view.pairing.detail.stringValue += " Choose the Apple TV to try again."
            pairer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.pairer == nil, self.view.showsPairing else { return }
                self.showDeviceList()
            }
        default:
            break
        }
    }

    @objc func pinChanged() {
        let digits = view.pairing.pin.stringValue.filter(\.isNumber)
        if digits != view.pairing.pin.stringValue { view.pairing.pin.stringValue = String(digits.prefix(4)) }
        if digits.count == 4 { pinEntered() }
    }

    @objc func pinEntered() {
        let digits = view.pairing.pin.stringValue.filter(\.isNumber)
        guard digits.count == 4, let p = pairer, p.status == .waitingForPIN else { return }
        p.submitPIN(digits)
    }

    @objc func cancelPairing() {
        pairer?.disconnect()
        pairer = nil
        if remote != nil {
            view.showsPairing = false
            window.makeFirstResponder(view)
            updateHeader()
        } else {
            showDeviceList()
        }
    }
}
