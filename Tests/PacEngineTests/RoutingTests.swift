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

    @Test func listsAndRemovesStaticRoutes() throws {
        let (_, _, rt) = try setup()
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        let rows = { rt.view().map { "\($0.isStatic ? "static" : "connected") \(formatIp($0.network))/\($0.prefix) \($0.nextHop.map(formatIp) ?? "-") \($0.iface)" } }
        #expect(rows() == [
            "connected 10.0.1.0/24 - eth0",
            "connected 10.0.12.0/30 - eth1",
            "static 10.0.2.0/24 10.0.12.2 eth1",
        ])
        try rt.removeStatic("10.0.2.7/24")
        #expect(try hop(rt, "10.0.2.1") == nil)
        #expect(rows().count == 2)
    }

    @Test func aLearnedRouteLosesToConnectedAndStaticOnesOfTheSamePrefixAndBeatsTheDhcpDefault() throws {
        let (_, node, rt) = try setup()
        let eth1 = try node.iface("eth1")
        let via = try parseIp("10.0.12.2")
        rt.learned = [
            LearnedRoute(network: try parseIp("10.0.2.0"), prefix: 24, nextHop: via, iface: eth1, metric: 1),
            LearnedRoute(network: try parseIp("10.0.3.0"), prefix: 24, nextHop: via, iface: eth1, metric: 2),
            LearnedRoute(network: try parseIp("10.0.1.0"), prefix: 24, nextHop: via, iface: eth1, metric: 1),
            LearnedRoute(network: 0, prefix: 0, nextHop: via, iface: eth1, metric: 4),
        ]
        rt.dhcpGateway = try parseIp("10.0.1.254")
        try rt.addStatic("10.0.3.0/24", "10.0.1.253")
        #expect(try hop(rt, "10.0.2.9") == "eth1 via 10.0.12.2")
        #expect(try hop(rt, "10.0.3.9") == "eth0 via 10.0.1.253") // static: distance 1 < 120
        #expect(try hop(rt, "10.0.1.9") == "eth0 via 10.0.1.9") // connected: distance 0
        #expect(try hop(rt, "8.8.8.8") == "eth1 via 10.0.12.2") // RIP 120 beats the DHCP default's 254
        #expect(rt.view().filter { $0.metric != nil }.map { "\(formatIp($0.network))/\($0.prefix) \($0.metric!)" } == ["10.0.2.0/24 1", "0.0.0.0/0 4"])
        let (n1, n2, n3) = (try parseIp("10.0.1.0"), try parseIp("10.0.2.0"), try parseIp("10.0.3.0"))
        #expect(rt.shadows(n3, 24) && rt.shadows(n1, 24) && !rt.shadows(n2, 24))
    }
}
