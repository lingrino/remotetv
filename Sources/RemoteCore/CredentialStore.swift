import Foundation

/// Pairings, one per Apple TV, in `~/Library/Application Support/RemoteTV/pairings.tsv`
/// (mode 0600): `name<TAB>clientID<TAB>clientSeed<TAB>serverID<TAB>serverPublicKey`, all
/// but the name in hex, most recently used first. A plain file rather than the Keychain:
/// one user, no prompts, readable by `tvctl` too, and loading it is one small read.
/// The client seed controls the TV, so the file is private to the user.
public struct CredentialStore: Sendable {
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var credentials: Credentials
    }

    public let url: URL
    public private(set) var entries: [Entry] = []
    /// Lines this version can't read (hand edits, a future format): written back untouched.
    private var unreadLines: [Substring] = []
    /// The file exists but couldn't be read: saving would replace every pairing, so don't.
    private var unreadable = false

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/RemoteTV/pairings.tsv", directoryHint: .notDirectory)
    }

    public init(url: URL = CredentialStore.defaultURL) {
        self.url = url
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            unreadable = FileManager.default.fileExists(atPath: url.path)
            return
        }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 5, let cid = Hex.decode(f[1]), let seed = Hex.decode(f[2]), seed.count == 32,
                  let sid = Hex.decode(f[3]), let pk = Hex.decode(f[4]), pk.count == 32 else {
                unreadLines.append(line)
                continue
            }
            entries.append(Entry(name: String(f[0]),
                                 credentials: Credentials(clientID: cid, clientSeed: seed, serverID: sid, serverPublicKey: pk)))
        }
    }

    /// Names are stored as one TSV field: tabs and newlines become spaces, both when saving
    /// and when looking up, so a name with a tab still finds its pairing.
    static func key(_ name: String) -> String {
        name.replacing("\t", with: " ").replacing("\n", with: " ")
    }

    public func credentials(for name: String) -> Credentials? {
        let k = CredentialStore.key(name)
        return entries.first { $0.name == k }?.credentials
    }

    /// The paired TV meant by `name`: as stored, or the one that differs only in case.
    public func name(matching name: String) -> String? {
        let k = CredentialStore.key(name)
        if entries.contains(where: { $0.name == k }) { return k }
        let found = entries.filter { $0.name.lowercased() == k.lowercased() }
        return found.count == 1 ? found[0].name : nil
    }

    /// The most recently used Apple TV.
    public var last: String? { entries.first?.name }

    /// Stores (or replaces) a pairing and makes it the most recent.
    public mutating func save(_ name: String, _ c: Credentials) throws {
        let k = CredentialStore.key(name)
        entries.removeAll { $0.name == k }
        entries.insert(Entry(name: k, credentials: c), at: 0)
        try write()
    }

    /// Marks a TV as the most recently used.
    public mutating func touch(_ name: String) throws {
        let k = CredentialStore.key(name)
        guard let i = entries.firstIndex(where: { $0.name == k }), i != 0 else { return }
        entries.insert(entries.remove(at: i), at: 0)
        try write()
    }

    public mutating func remove(_ name: String) throws {
        let k = CredentialStore.key(name)
        entries.removeAll { $0.name == k }
        try write()
    }

    /// Atomic replace: a new 0600 file (created that way, never wider), written, synced,
    /// then renamed over the old one.
    private func write() throws {
        guard !unreadable else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var text = ""
        for e in entries {
            let c = e.credentials
            text += "\(e.name)\t\(Hex.encode(c.clientID))\t\(Hex.encode(c.clientSeed))\t\(Hex.encode(c.serverID))\t\(Hex.encode(c.serverPublicKey))\n"
        }
        for l in unreadLines { text += l + "\n" }
        let tmp = url.path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp]) }
        let bytes = Array(text.utf8)
        let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard n == bytes.count, synced, rename(tmp, url.path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// Lowercase hex, and back (nil on odd length or a non-hex character).
enum Hex {
    static func encode(_ b: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(b.count * 2)
        for x in b { out.append(digits[Int(x >> 4)]); out.append(digits[Int(x & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ s: some StringProtocol) -> [UInt8]? {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: nil
        }
    }
}
