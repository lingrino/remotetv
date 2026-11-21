import AppKit
import RemoteCore

/// The `tvctl` command line's way in: a Unix socket at
/// `~/Library/Application Support/RemoteTV/control.sock` (mode 0600, this user only).
/// Commands run on the app's own session, so scripts and the window never fight over the
/// TV's one-connection-per-pairing limit and nothing waits for a handshake.
///
/// Wire format: one request line, arguments separated by U+001F, then "\n". The reply is
/// text; its last line is "\u{1F}<exit code>". Requests are handled on the main thread;
/// the socket thread waits (up to 15 s) for the reply.
final class ControlServer: @unchecked Sendable {
    static let path = CredentialStore.defaultURL.deletingLastPathComponent().appending(path: "control.sock").path
    private let handler: @MainActor ([String], @escaping @MainActor (String, Int32) -> Void) -> Void

    init(handler: @escaping @MainActor ([String], @escaping @MainActor (String, Int32) -> Void) -> Void) {
        self.handler = handler
    }

    func start() {
        let path = ControlServer.path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let b = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: b)
            raw[b.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return }
        chmod(path, 0o600)
        listen(fd, 8)
        let t = Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { usleep(100_000); continue }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                // Each client on its own thread: a slow command (waiting for the TV) must
                // not hold up the next one.
                Thread { self.serve(c) }.start()
            }
        }
        t.qualityOfService = .utility
        t.start()
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var buf = [UInt8](repeating: 0, count: 4096)
        var data: [UInt8] = []
        while !data.contains(0x0A) && data.count < 64 << 10 {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data += buf[0..<n]
        }
        let line = String(decoding: data.prefix { $0 != 0x0A }, as: UTF8.self)
        let args = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out = "timed out\n"
        nonisolated(unsafe) var code: Int32 = 1
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var replied = false
                self.handler(args) { text, status in
                    guard !replied else { return }
                    replied = true
                    out = text
                    code = status
                    done.signal()
                }
            }
        }
        _ = done.wait(timeout: .now() + 15)
        var reply = out
        if !reply.isEmpty && !reply.hasSuffix("\n") { reply += "\n" }
        reply += "\u{1F}\(code)\n"
        let bytes = Array(reply.utf8)
        _ = bytes.withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
    }
}
