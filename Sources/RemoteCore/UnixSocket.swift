import Darwin

/// `sockaddr_un` for the control socket, shared by the app and tvctl. Nil when the path
/// doesn't fit `sun_path` (104 bytes) — never silently truncated.
public enum UnixSocket {
    public static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
            return true
        }
        return fits ? addr : nil
    }

    /// A connected client socket, or nil.
    public static func connect(_ path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }
}
