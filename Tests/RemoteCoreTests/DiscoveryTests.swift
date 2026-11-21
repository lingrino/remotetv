import Testing
import Network
@testable import RemoteCore

@Test func deviceEndpointIsBonjourService() {
    let d = Device(name: "Living Room")
    guard case let .service(name, type, domain, _) = d.endpoint else {
        Issue.record("not a service endpoint")
        return
    }
    #expect(name == "Living Room")
    #expect(type == "_companion-link._tcp")
    #expect(domain == "local.")
}
