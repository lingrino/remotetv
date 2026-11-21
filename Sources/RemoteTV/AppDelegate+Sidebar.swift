import AppKit
import RemoteCore

/// The sidebar's window side: opening/closing (widening the window), loading its data.
@MainActor
extension AppDelegate {
    // MARK: - Sidebar

    @objc func toggleSidebar() { setSidebar(!sidebarOpen, animate: true) }

    /// Opens or closes the sidebar by widening the window to the right (the remote stays
    /// where it is; near the screen's right edge the window shifts left to fit).
    func setSidebar(_ open: Bool, animate: Bool) {
        guard open != sidebarOpen, let window else { return }
        sidebarOpen = open
        UserDefaults.standard.set(open, forKey: "sidebarOpen")
        let h = RemoteView.height
        let width = open ? Theme.width + Sidebar.width + Sidebar.inset : Theme.width
        if open {
            let s = sidebar ?? makeSidebar()
            s.isHidden = false
        }
        var f = window.frame
        f.size.width = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: h)).width
        if open, let vis = window.screen?.visibleFrame, f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
        window.setFrame(f, display: true, animate: animate)
        root.frame = NSRect(x: 0, y: 0, width: width, height: h)
        if !open { sidebar?.isHidden = true }
        view.sidebarButton.contentTintColor = open ? .labelColor : .secondaryLabelColor
        remote?.wantsArtwork = open && window.isVisible
        if open { loadSidebar() }
    }

    func makeSidebar() -> Sidebar {
        let s = Sidebar(frame: NSRect(x: Theme.width, y: Sidebar.inset, width: Sidebar.width,
                                      height: RemoteView.height - 2 * Sidebar.inset))
        s.onPlay = { [weak self] item in
            guard let url = item.actionURL else { return }
            self?.remote?.open(url: url)
        }
        s.onLaunch = { [weak self] app in self?.remote?.launch(bundleID: app.bundleID) }
        s.onTab = { UserDefaults.standard.set($0, forKey: "sidebarTab") }
        s.tab = UserDefaults.standard.integer(forKey: "sidebarTab")
        root.addSubview(s)
        sidebar = s
        return s
    }

    /// Fresh Up Next every time it's shown (it changes as you watch); apps (with icons)
    /// once per run, unless the installed set changed.
    func loadSidebar() {
        guard let r = remote, let s = sidebar else { return }
        s.setNowPlaying(r.nowPlaying, app: app(for: r.nowPlaying?.bundleID))
        if upNext == nil { s.setUpNext(nil) }   // "Loading…" until the first answer
        r.fetchUpNext { [weak self] items in
            guard let self else { return }
            if let items { self.upNext = items }
            // A failed fetch keeps what was there (the TV's Up Next service has hiccups).
            self.sidebar?.setUpNext(items ?? self.upNext, failed: items == nil && self.upNext == nil)
        }
        if tvApps == nil { s.setApps(nil) } else { s.setApps(tvApps) }
        guard !loadingApps else { return }
        loadingApps = true
        r.fetchApps(icons: false) { [weak self] names in
            guard let self else { return }
            if let have = self.tvApps, Set(have.map(\.bundleID)) == Set(names.map(\.bundleID)) {
                self.loadingApps = false
                return
            }
            r.fetchApps(icons: true) { [weak self] apps in
                guard let self else { return }
                self.loadingApps = false
                self.tvApps = apps
                self.sidebar?.setApps(apps)
                self.sidebar?.setNowPlaying(r.nowPlaying, app: self.app(for: r.nowPlaying?.bundleID))
            }
        }
    }

    func app(for bundleID: String?) -> TVApp? {
        guard let bundleID else { return nil }
        return tvApps?.first { $0.bundleID == bundleID }
    }
}
