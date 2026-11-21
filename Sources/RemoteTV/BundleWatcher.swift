import AppKit
import CoreServices

/// Notices RemoteTV.app being replaced on disk: `brew upgrade` swaps the bundle under the
/// running process, which would otherwise keep running the old code until the next quit.
/// FSEvents on the enclosing folder, file-level and filtered to this bundle's path (path
/// based, so the new bundle landing at the same path is seen; the folder rarely changes,
/// so it costs nothing). Fires once the executable is a different file, 2 s after the last
/// change (an upgrade moves the old bundle out, then the new one in).
@MainActor
final class BundleWatcher {
    var onReplaced: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let bundle = Bundle.main.bundlePath
    private let launched = BundleWatcher.fileID(Bundle.main.executablePath)

    func start() {
        guard stream == nil else { return }
        let folder = (bundle as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<BundleWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            MainActor.assumeIsolated { me.changed(list) }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func changed(_ paths: [String]) {
        guard paths.contains(where: { $0 == bundle || $0.hasPrefix(bundle + "/") }) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let now = BundleWatcher.fileID(Bundle.main.executablePath), now != self.launched else { return }
                self.onReplaced?()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    /// Inode and modification time: a replaced executable differs in at least one.
    private static func fileID(_ path: String?) -> [Int]? {
        guard let path else { return nil }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return [Int(st.st_ino), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
    }

    /// Quits and opens the bundle at the same path again once this process is gone (the
    /// new one must not overlap: one TV connection per pairing, one control socket).
    /// `activate: false` opens it without taking focus (`open -g`).
    static func relaunch(activate: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.05; done; exec /usr/bin/open \(activate ? "" : "-g ")\"$0\"",
                       Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
