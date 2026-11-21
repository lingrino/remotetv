import AppKit
import RemoteCore
import os

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
        let log = Logger(subsystem: "com.lingrino.remotetv", category: "control")
        guard var addr = UnixSocket.address(path) else {
            return log.error("control socket path too long: \(path, privacy: .private)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return log.error("control socket: socket() failed \(errno)") }
        // Created 0600 from the start (umask), not chmod'ed after bind.
        let old = umask(0o177)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard ok == 0 else {
            close(fd)
            return log.error("control socket: bind failed \(errno)")
        }
        listen(fd, 8)
        let t = Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { usleep(100_000); continue }
                // Only this user's processes (the file is 0600 too; defense in depth).
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
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
        let result = Reply()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.handler(args) { text, status in result.set(text, status) }
            }
        }
        let (text, code) = result.wait(seconds: 15)
        var reply = text
        if !reply.isEmpty && !reply.hasSuffix("\n") { reply += "\n" }
        reply += "\u{1F}\(code)\n"
        let bytes = Array(reply.utf8)
        _ = bytes.withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
    }

    /// The handler's answer, handed from the main thread to the socket thread (first answer
    /// wins; a late one after the timeout is ignored).
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: (String, Int32)?

        func set(_ text: String, _ code: Int32) {
            lock.lock()
            defer { lock.unlock() }
            guard value == nil else { return }
            value = (text, code)
            done.signal()
        }

        func wait(seconds: Double) -> (String, Int32) {
            _ = done.wait(timeout: .now() + seconds)
            lock.lock()
            defer { lock.unlock() }
            if let value { return value }
            value = ("timed out", 1)
            return ("timed out", 1)
        }
    }
}
