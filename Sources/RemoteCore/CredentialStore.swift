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

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/RemoteTV/pairings.tsv", directoryHint: .notDirectory)
    }

    public init(url: URL = CredentialStore.defaultURL) {
        self.url = url
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 5, let cid = hexBytes(f[1]), let seed = hexBytes(f[2]), seed.count == 32,
                  let sid = hexBytes(f[3]), let pk = hexBytes(f[4]), pk.count == 32 else { continue }
            entries.append(Entry(name: String(f[0]),
                                 credentials: Credentials(clientID: cid, clientSeed: seed, serverID: sid, serverPublicKey: pk)))
        }
    }

    public func credentials(for name: String) -> Credentials? {
        entries.first { $0.name == name }?.credentials
    }

    /// The most recently used Apple TV.
    public var last: String? { entries.first?.name }

    /// Stores (or replaces) a pairing and makes it the most recent.
    public mutating func save(_ name: String, _ c: Credentials) throws {
        entries.removeAll { $0.name == name }
        entries.insert(Entry(name: name, credentials: c), at: 0)
        try write()
    }

    /// Marks a TV as the most recently used.
    public mutating func touch(_ name: String) throws {
        guard let i = entries.firstIndex(where: { $0.name == name }), i != 0 else { return }
        entries.insert(entries.remove(at: i), at: 0)
        try write()
    }

    public mutating func remove(_ name: String) throws {
        entries.removeAll { $0.name == name }
        try write()
    }

    private func write() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var text = ""
        for e in entries {
            let c = e.credentials
            let name = e.name.replacing("\t", with: " ").replacing("\n", with: " ")
            text += "\(name)\t\(hex(c.clientID))\t\(hex(c.clientSeed))\t\(hex(c.serverID))\t\(hex(c.serverPublicKey))\n"
        }
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, url.path) == 0
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}

func hex(_ b: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(b.count * 2)
    for x in b { out.append(digits[Int(x >> 4)]); out.append(digits[Int(x & 15)]) }
    return String(decoding: out, as: UTF8.self)
}

func hexBytes(_ s: Substring) -> [UInt8]? {
    let u = Array(s.utf8)
    guard u.count % 2 == 0 else { return nil }
    var out = [UInt8]()
    out.reserveCapacity(u.count / 2)
    var i = 0
    while i < u.count {
        guard let hi = nib(u[i]), let lo = nib(u[i + 1]) else { return nil }
        out.append(hi << 4 | lo)
        i += 2
    }
    return out
}

private func nib(_ c: UInt8) -> UInt8? {
    switch c {
    case 48...57: c - 48
    case 97...102: c - 87
    case 65...70: c - 55
    default: nil
    }
}
