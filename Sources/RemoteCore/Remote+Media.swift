import Foundation
import Network
import os

/// The AirPlay/MRP side: started with every session, never blocking the remote; the
/// now-playing source while it is up.
extension Remote {
    // MARK: - MRP (AirPlay tunnel)


    func startMedia() {
        // The AirPlay service is found by the TV's Bonjour name; a TV reached any other way
        // (tests) has no tunnel.
        guard media == nil, let credentials, case .service = device.endpoint else { return }
        let m = MediaRemote(device: device, credentials: credentials, name: clientName)
        m.wantsArtwork = wantsArtwork
        media = m
        m.onReady = { [weak self, weak m] ok in
            guard let self, let m, m === self.media else { return }
            if ok { self.mediaFailures = 0 }
            Remote.log.info("\(self.device.name, privacy: .public): MRP \(ok ? "ready" : "down", privacy: .public)")
            self.onMediaReady?(ok)
            self.publishNowPlaying()
        }
        m.onNowPlaying = { [weak self, weak m] _ in
            guard let self, let m, m === self.media else { return }
            self.publishNowPlaying()
        }
        m.onTunnel = { [weak self, weak m] s in
            guard let self, let m, m === self.media, case .failed(let e) = s else { return }
            Remote.log.notice("AirPlay tunnel: \(e, privacy: .public)")
            self.scheduleMediaRetry()
        }
        m.start()
    }

    func scheduleMediaRetry() {
        mediaRetry?.cancel()
        let delays: [Double] = [2, 5, 15, 30, 60]
        let delay = delays[min(mediaFailures, delays.count - 1)]
        mediaFailures += 1
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .session = self.phase, let m = self.media else { return }
                m.start()
            }
        }
        mediaRetry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func stopMedia() {
        mediaRetry?.cancel()
        mediaRetry = nil
        let had = media?.isReady == true
        media?.onReady = nil
        media?.onNowPlaying = nil
        media?.onTunnel = nil
        media?.stop()
        media = nil
        if had { onMediaReady?(false) }
    }

    /// MRP's now playing when the tunnel is up (every app reports to it), else Companion's;
    /// subtitle availability/state always from Companion (MRP doesn't carry it simply).
    func publishNowPlaying() {
        var np = media?.isReady == true ? media?.nowPlaying : companionPlaying
        if var n = np, let c = companionPlaying {
            if !n.captionsFromMRP {
                n.captionsEnabled = c.captionsEnabled
                n.hasCaptions = c.hasCaptions
            }
            n.bundleID = n.bundleID ?? c.bundleID
            np = n
        }
        guard np != nowPlaying else { return }
        nowPlaying = np
        onNowPlaying?(np)
    }
}
