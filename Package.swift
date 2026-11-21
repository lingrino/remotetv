// swift-tools-version: 6.4
import PackageDescription

// RemoteCore is the Apple TV protocol stack (OPACK, TLV8, binary plists, protobuf, SRP,
// HAP pairing, Companion and AirPlay framing, the client). It has no AppKit and is
// unit-tested. It parses data from the network, some of it before the peer is
// authenticated (pairing messages, AirPlay pair-verify), so release builds keep Swift's
// bounds and overflow checks: a missed check traps instead of reading memory. The hot path
// (a key press) is a few dozen bytes of OPACK and one ChaCha20 seal: unchecked builds
// aren't worth the risk.
let wmo: [SwiftSetting] = [.unsafeFlags(["-wmo"], .when(configuration: .release))]

let package = Package(
    name: "remotetv",
    platforms: [.macOS("27.2")],   // the minimum, by the user's decision (AGENTS.md)
    products: [
        .executable(name: "RemoteTV", targets: ["RemoteTV"]),
        .executable(name: "tvctl", targets: ["TVCtl"]),
    ],
    targets: [
        .target(name: "RemoteCore", swiftSettings: wmo),
        .executableTarget(
            name: "RemoteTV",
            dependencies: ["RemoteCore"],
            swiftSettings: wmo,
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Command-line client over the same core: scan, pair, press buttons. For testing
        // the protocol against a real Apple TV without the UI.
        .executableTarget(name: "TVCtl", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
    ]
)
