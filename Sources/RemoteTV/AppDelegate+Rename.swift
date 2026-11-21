import AppKit
import RemoteCore

/// Following a renamed TV: the pairing moves to the TV that can prove it holds it.
@MainActor
extension AppDelegate {
    // MARK: - Renamed TVs


    /// Pairings are stored by the TV's name, which is also how it's found (Bonjour). If
    /// the TV was renamed, the old name is gone; any Apple TV on the network whose name
    /// isn't paired is tried with the current credentials: pair-verify only succeeds on
    /// the TV that holds them (it proves its identity), and then the pairing moves over.
    func followRename() {
        guard renameProbe == nil, Date().timeIntervalSince(lastRenameProbe) > 30,
              let r = remote, let creds = r.credentials else { return }
        let paired = Set(store.entries.map(\.name))
        guard let candidate = devices.first(where: { !paired.contains($0.name) && !renameTried.contains($0.name) })
        else { return }
        renameTried.insert(candidate.name)
        lastRenameProbe = Date()
        let old = r.device.name
        let p = Remote(device: candidate, credentials: creds)
        renameProbe = p
        p.onStatus = { [weak self, weak p] s in
            guard let self, let p, p === self.renameProbe else { return }
            switch s {
            case .connected:
                AppDelegate.log.notice("\(old, privacy: .public) is now \(candidate.name, privacy: .public)")
                self.renameProbe = nil
                try? self.store.remove(old)
                try? self.store.save(candidate.name, creds)
                self.remote?.disconnect()
                self.remote = p
                self.adopt(p)
                self.showRemote(p)
                self.statusChanged(s)
            case .failed, .unpaired:
                self.renameProbe = nil
                p.disconnect()
            default:
                break
            }
        }
        p.connect()
    }

    /// Reconnects after a failure while the app is in use: quickly at first (a TV that
    /// just woke up), then backing off to every 8 s.
    func scheduleRetry() {
        retryItem?.cancel()
        guard window?.isVisible == true, remote?.isPaired == true else { return }
        let delays: [Double] = [0.3, 1, 2, 4, 8]
        let delay = delays[min(retryCount, delays.count - 1)]
        retryCount += 1
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.remote?.connect() }
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func reconnectIfNeeded() {
        guard let r = remote, r.isPaired else { return }
        switch r.status {
        case .failed, .idle:
            retryItem?.cancel()
            retryCount = 0
            r.connect()
        default:
            break
        }
    }

    func updateHeader() {
        guard window != nil else { return }
        guard let r = remote, !view.showsPairing else {
            view.title.title = "RemoteTV"
            return
        }
        view.title.title = r.device.name
        let status: String? = switch r.status {
        case .connected, .idle: nil
        case .connecting, .pairing: "Connecting…"
        case .unpaired: "\(r.device.name) forgot this Mac. Pair again from the menu above."
        case .failed(.localNetworkDenied):
            "Local Network access is off. Click to allow it."
        case .waitingForPIN: "Pairing…"
        case .failed(let e): e.description.prefix(1).uppercased() + e.description.dropFirst()
        }
        view.strip.show(status == nil ? r.nowPlaying : nil, status: status, seekable: r.canSeek)
        view.setPower(asleep: r.power == .asleep)
        if sidebarOpen { sidebar?.setNowPlaying(status == nil ? r.nowPlaying : nil, app: app(for: r.nowPlaying?.bundleID)) }
        let known = r.controlsKnown && r.status == .connected
        let volume = !known || r.controls.contains(.volume)
        view.setAvailability(skip: !known || r.controls.contains(.skipForward) || r.controls.contains(.skipBackward),
                             volume: volume)
        view.volume.muteAvailable = r.muteAvailable && volume
        let np = r.nowPlaying
        view.setCaptions(available: np?.hasCaptions ?? false, on: np?.captionsEnabled ?? false)
        updateTicker()
    }
}
