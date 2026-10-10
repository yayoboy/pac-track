import Testing
@testable import PacEngine

@Suite struct Ipv6ServicesTests {
    /// M9a review: "fe80::1%eth0" said "Invalid IPv6 address" instead of the typed error.
    @Test func zonesGetTheLinkLocalErrorAndNothingElse() throws {
        let sim = Sim()
        let a = Host(sim: sim, id: "A")
        withExtendedLifetime(sim) {
            expectError("Ping to link-local or multicast addresses is not supported") { _ = try Ping(node: a, target: "fe80::1%eth0") }
            expectError("Traceroute to link-local or multicast addresses is not supported") { _ = try Traceroute(node: a, target: "ff02::1%eth0") }
            expectError("Invalid IPv6 address: \"2001:db8::1%eth0\"") { _ = try Ping(node: a, target: "2001:db8::1%eth0") }
            expectError("Invalid IPv6 address: \"fe80::zz\"") { _ = try Ping(node: a, target: "fe80::zz%eth0") } // the address part is parsed first
        }
    }
}
