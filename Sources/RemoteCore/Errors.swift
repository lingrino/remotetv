/// Everything that can go wrong talking to an Apple TV, as one error type so callers can
/// show a single line to the user.
public enum ProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A message didn't parse (truncated, wrong type, missing field).
    case malformed(String)
    /// Pairing or pair-verify was rejected or failed a cryptographic check.
    case authentication(String)
    /// The Apple TV answered a request with an error (`_em`).
    case remote(String)
    /// The connection failed or closed.
    case connection(String)
    case timeout

    public var description: String {
        switch self {
        case .malformed(let s): "bad message: \(s)"
        case .authentication(let s): s
        case .remote(let s): "Apple TV error: \(s)"
        case .connection(let s): s
        case .timeout: "the Apple TV didn't answer"
        }
    }
}
