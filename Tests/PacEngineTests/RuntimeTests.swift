import Testing
@testable import PacEngine

private func lanRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "b", kind: .pc, name: "PC2"))
    try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/1")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "b", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2")))
    try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
    try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.2/24"))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct RuntimeTests {
    @Test func buildsANetworkFromCommandsAndReportsItInTheSnapshot() throws {
        let s = try lanRuntime().snapshot()
        #expect(s.nodes.map { "\($0.name):\($0.kind.rawValue)" } == ["PC1:pc", "PC2:pc", "SW1:switch"])
        #expect(s.nodes[0].ifaces.map { "\($0.name) \($0.cidr ?? "-") \($0.linked)" } == ["eth0 10.0.0.1/24 true"])
        #expect(s.nodes[0].routes == [RouteRow(dest: "10.0.0.0/24", nextHop: nil, iface: "eth0", isStatic: false)])
        #expect(s.links.map(\.id) == ["l1", "l2"])
        #expect(s.links[1] == LinkView(id: "l2", a: IfaceRef(node: "b", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2")))
    }

    @Test func runsPingAsAnAppAndFillsArpAndMacTables() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 15_000)
        let s = rt.snapshot()
        #expect(s.apps.count == 1)
        #expect(s.apps[0].node == "a" && s.apps[0].title == "ping 10.0.0.2" && s.apps[0].done)
        #expect(s.apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(s.nodes[0].arp.map(\.ip) == ["10.0.0.2"])
        #expect(s.nodes[2].mac.count == 2)
    }

    @Test func advancesSimulatedTimeByWallTimeTimesSpeedClampedAndOnlyWhileRunning() throws {
        let rt = Runtime()
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().timeNs == 50_000_000)
        try rt.handle(.setSpeed(10))
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().timeNs == 550_000_000)
        rt.advance(wallMs: 600_000) // ten minutes asleep: only 100 ms of wall time count
        #expect(rt.snapshot().timeNs == 1_550_000_000)
        try rt.handle(.setRunning(false))
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().timeNs == 1_550_000_000)
        expectError("Invalid speed") { try rt.handle(.setSpeed(0)) }
    }

    @Test func rejectsInvalidCommandsWithClearErrorsAndNoSideEffects() throws {
        let rt = try lanRuntime()
        expectError("Invalid IPv4") { try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.300/24")) }
        expectError("already exists") { try rt.handle(.addNode(id: "a", kind: .pc, name: "X")) }
        expectError("already connected") {
            try rt.handle(.connect(id: "l3", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/3")))
        }
        expectError("no IP stack") { try rt.handle(.ping(node: "s", target: "10.0.0.1")) }
        expectError("Unknown node") { try rt.handle(.removeNode(id: "zz")) }
        expectError("empty") { try rt.handle(.rename(id: "a", name: "  ")) }
        #expect(rt.snapshot().nodes[0].ifaces[0].cidr == "10.0.0.1/24")
        #expect(rt.snapshot().links.count == 2)
    }

    @Test func removingANodeRemovesItsCablesAndStopsItsApps() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        try rt.handle(.removeNode(id: "s"))
        try rt.handle(.removeNode(id: "a"))
        let s = rt.snapshot()
        #expect(s.links.isEmpty)
        #expect(s.nodes.map { $0.ifaces[0].linked } == [false])
        #expect(s.apps[0].done)
    }

    @Test func removingANodeWithFramesInFlightIsSafe() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        rt.advance(wallMs: 0.0005) // 500 ns: the first ARP frame is still on the wire
        try rt.handle(.removeNode(id: "s"))
        runFor(rt, wallMs: 3_000)
        #expect(rt.snapshot().nodes.map(\.name) == ["PC1", "PC2"])
    }

    @Test func clearsAnAddressAndManagesStaticRoutes() throws {
        let rt = try lanRuntime()
        try rt.handle(.addRoute(node: "a", cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        #expect(rt.snapshot().nodes[0].routes.last == RouteRow(dest: "0.0.0.0/0", nextHop: "10.0.0.254", iface: "eth0", isStatic: true))
        try rt.handle(.removeRoute(node: "a", cidr: "0.0.0.0/0"))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: nil))
        #expect(rt.snapshot().nodes[0].routes.isEmpty)
        #expect(rt.snapshot().nodes[0].ifaces[0].cidr == nil)
    }

    @Test func snapshotVersionsStrictlyIncrease() throws {
        let rt = try lanRuntime()
        let v1 = rt.snapshot().version
        rt.advance(wallMs: 10)
        #expect(rt.snapshot().version > v1)
    }

    @Test func loadsATopologyAtomically() throws {
        let rt = try lanRuntime()
        let t = Topology(seed: 7, nodes: [
            TopologyNode(id: "r", kind: .router, name: "R1", pos: Pos(x: 0, y: 0), ifaces: [
                TopologyIface(name: "Gi0/0", cidr: "10.0.1.1/24"), TopologyIface(name: "Gi0/1", cidr: nil),
            ], routes: []),
            TopologyNode(id: "h", kind: .pc, name: "H1", pos: Pos(x: 0, y: 0),
                         ifaces: [TopologyIface(name: "eth0", cidr: "10.0.1.10/24")],
                         routes: [TopologyRoute(cidr: "0.0.0.0/0", nextHop: "10.0.1.1")]),
        ], links: [LinkView(id: "x", a: IfaceRef(node: "h", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0"))])
        rt.advance(wallMs: 50)
        try rt.handle(.load(t))
        let s = rt.snapshot()
        #expect(s.seed == 7 && s.timeNs == 0)
        #expect(s.nodes.map(\.name) == ["R1", "H1"])
        #expect(s.nodes[1].routes.last?.nextHop == "10.0.1.1")

        var badLink = t
        badLink.links = [LinkView(id: "y", a: IfaceRef(node: "h", iface: "eth9"), b: IfaceRef(node: "r", iface: "Gi0/1"))]
        expectError("no interface eth9") { try rt.handle(.load(badLink)) }
        var badVersion = t
        badVersion.version = 2
        expectError("Unsupported or corrupt") { try rt.handle(.load(badVersion)) }
        #expect(rt.snapshot().nodes.map(\.name) == ["R1", "H1"])
    }
}
