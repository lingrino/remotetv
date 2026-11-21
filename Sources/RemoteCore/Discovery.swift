import Network

/// An Apple TV advertising the Companion Link service (`_companion-link._tcp`), the
/// channel the iPhone remote uses. Identified by its Bonjour instance name, which is the
/// name set on the TV ("Living Room"); connecting goes through the service endpoint, so
/// the address is resolved by mDNS at connect time and DHCP changes don't matter.
public struct Device: Sendable, Hashable, Identifiable {
    public let name: String
    /// `rpMd` from the TXT record ("AppleTV14,1"); empty if missing.
    public let model: String
    public let endpoint: NWEndpoint

    public var id: String { name }

    public init(name: String, model: String = "") {
        self.name = name
        self.model = model
        self.endpoint = Device.endpoint(name: name)
    }

    init(name: String, model: String, endpoint: NWEndpoint) {
        self.name = name
        self.model = model
        self.endpoint = endpoint
    }

    public static let serviceType = "_companion-link._tcp"

    public static func endpoint(name: String) -> NWEndpoint {
        .service(name: name, type: serviceType, domain: "local.", interface: nil)
    }
}

/// Browses for Apple TVs. Macs, iPhones and iPads advertise the same service; only
/// `AppleTV*` models are reported. Runs on the main queue; `onChange` gets the full,
/// name-sorted list every time it changes.
@MainActor
public final class Browser {
    private var browser: NWBrowser?
    private let onChange: @MainActor ([Device]) -> Void

    public init(onChange: @escaping @MainActor ([Device]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Device.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var devices: [Device] = []
        devices.reserveCapacity(results.count)
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            var model = ""
            if case let .bonjour(txt) = r.metadata, case let .string(md)? = txt.getEntry(for: "rpMd") {
                model = md
            }
            guard model.hasPrefix("AppleTV") else { continue }
            if devices.contains(where: { $0.name == name }) { continue }   // one per interface
            devices.append(Device(name: name, model: model, endpoint: Device.endpoint(name: name)))
        }
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onChange(devices)
    }
}
