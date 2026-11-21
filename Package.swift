// swift-tools-version: 6.4
import PackageDescription

// RemoteCore is the Apple TV protocol stack (OPACK, TLV8, SRP, HAP pairing, Companion
// framing and encryption, the client). It has no AppKit and is fully unit-tested. Its
// release build drops bounds/overflow/exclusivity checks: the code is small, tested in
// debug with every check on, and parses only frames that already passed authenticated
// decryption (pairing frames are bounds-checked explicitly).
let releaseFast: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-wmo"], .when(configuration: .release)),
]

let package = Package(
    name: "remotetv",
    platforms: [.macOS("27.2")],   // the minimum, by the user's decision (AGENTS.md)
    products: [
        .executable(name: "RemoteTV", targets: ["RemoteTV"]),
        .executable(name: "tvctl", targets: ["TVCtl"]),
    ],
    targets: [
        .target(name: "RemoteCore", swiftSettings: releaseFast),
        .executableTarget(
            name: "RemoteTV",
            dependencies: ["RemoteCore"],
            swiftSettings: [.unsafeFlags(["-wmo"], .when(configuration: .release))],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Command-line client over the same core: scan, pair, press buttons. For testing
        // the protocol against a real Apple TV without the UI.
        .executableTarget(name: "TVCtl", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
    ]
)
