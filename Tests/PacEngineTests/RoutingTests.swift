import Testing
@testable import PacEngine

private func setup() throws -> (sim: Sim, node: Probe, rt: RoutingTable) {
    let sim = Sim()
    let node = Probe(sim: sim, id: "R")
    node.addInterface("eth1")
    try node.iface("eth0").ipv4 = Cidr(addr: try parseIp("10.0.1.1"), prefix: 24)
    try node.iface("eth1").ipv4 = Cidr(addr: try parseIp("10.0.12.1"), prefix: 30)
    return (sim, node, RoutingTable(interfaces: { node.interfaces }))
}

private func hop(_ rt: RoutingTable, _ dst: String) throws -> String? {
    rt.lookup(try parseIp(dst)).map { "\($0.iface.name) via \(formatIp($0.nextHop))" }
}

@Suite struct RoutingTests {
    @Test func routesConnectedSubnetsDirectly() throws {
        let (_, _, rt) = try setup()
        #expect(try hop(rt, "10.0.1.50") == "eth0 via 10.0.1.50")
        #expect(try hop(rt, "10.0.12.2") == "eth1 via 10.0.12.2")
        #expect(try hop(rt, "8.8.8.8") == nil)
    }

    @Test func resolvesStaticRoutesLongestPrefixFirst() throws {
        let (_, _, rt) = try setup()
        try rt.addStatic("0.0.0.0/0", "10.0.1.254")
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        try rt.addStatic("10.0.2.128/25", "10.0.1.253")
        #expect(try hop(rt, "8.8.8.8") == "eth0 via 10.0.1.254")
        #expect(try hop(rt, "10.0.2.9") == "eth1 via 10.0.12.2")
        #expect(try hop(rt, "10.0.2.200") == "eth0 via 10.0.1.253")
    }

    @Test func rejectsStaticRoutesWhoseNextHopIsNotInAConnectedSubnet() throws {
        let (_, _, rt) = try setup()
        expectError("not in a connected subnet") { try rt.addStatic("172.16.0.0/16", "192.168.0.1") }
        #expect(try hop(rt, "172.16.5.5") == nil)
    }

    @Test func fallsBackToAShorterRouteWhenTheLongerOneLosesItsNextHop() throws {
        let (_, node, rt) = try setup()
        try rt.addStatic("0.0.0.0/0", "10.0.1.254")
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        try node.iface("eth1").up = false
        #expect(try hop(rt, "10.0.2.10") == "eth0 via 10.0.1.254")
    }

    @Test func dropsConnectedRoutesOfInterfacesThatAreDown() throws {
        let (_, node, rt) = try setup()
        try node.iface("eth0").up = false
        #expect(try hop(rt, "10.0.1.50") == nil)
    }

    @Test func replacesARouteWithTheSamePrefix() throws {
        let (_, _, rt) = try setup()
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        try rt.addStatic("10.0.2.7/24", "10.0.1.9") // normalised to 10.0.2.0/24
        #expect(try hop(rt, "10.0.2.1") == "eth0 via 10.0.1.9")
    }

    @Test func rejectsMalformedInputWithoutChangingTheTable() throws {
        let (_, _, rt) = try setup()
        expectError("Invalid CIDR") { try rt.addStatic("10.0.2.0/33", "10.0.12.2") }
        expectError("Invalid IPv4") { try rt.addStatic("10.0.2.0/24", "10.0.12") }
        #expect(try hop(rt, "10.0.2.1") == nil)
    }
}
