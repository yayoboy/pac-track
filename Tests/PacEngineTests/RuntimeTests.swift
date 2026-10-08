import Foundation
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

    @Test func simulationModeStopsTheClockAndStepsToTheNextLoggedEvent() throws {
        let rt = try lanRuntime()
        try rt.handle(.setMode(.simulation))
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        rt.advance(wallMs: 100)
        var s = rt.snapshot()
        #expect(s.mode == .simulation && !s.running && s.timeNs == 0 && s.eventCount == 0)
        try rt.handle(.step)
        s = rt.snapshot()
        #expect(s.eventCount == 1)
        #expect(rt.events(from: 0).map { "\($0.kind.rawValue) \($0.node) \($0.proto.rawValue)" } == ["tx a arp"])
        try rt.handle(.step) // the request reaches the switch, which floods it in the same instant
        #expect(rt.events(from: 1).map { "\($0.kind.rawValue) \($0.node)" } == ["rx s", "tx s"])
        #expect(rt.snapshot().timeNs == 1172)
        try rt.handle(.setMode(.realtime))
        #expect(rt.snapshot().running)
    }

    @Test func leavingSimulationModeRestoresThePausedState() throws {
        let rt = Runtime()
        try rt.handle(.setRunning(false))
        try rt.handle(.setMode(.simulation))
        try rt.handle(.setMode(.realtime))
        #expect(!rt.snapshot().running)
    }

    @Test func simulationPlayStepsTwicePerSecondOfWallTimeAtSpeedOne() throws {
        let played = try lanRuntime()
        let stepped = try lanRuntime()
        for rt in [played, stepped] {
            try rt.handle(.setMode(.simulation))
            try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        }
        try played.handle(.setRunning(true))
        runFor(played, wallMs: 1000)
        try stepped.handle(.step)
        try stepped.handle(.step)
        #expect(played.snapshot().eventCount == stepped.snapshot().eventCount)
        #expect(played.snapshot().timeNs == stepped.snapshot().timeNs)
    }

    @Test func stepWithAnEmptyQueueDoesNothing() throws {
        let rt = Runtime()
        try rt.handle(.setMode(.simulation))
        try rt.handle(.step)
        #expect(rt.snapshot().timeNs == 0 && rt.snapshot().eventCount == 0)
    }

    @Test func snapshotVersionChangesOnlyWhenTheContentDoes() throws {
        let rt = try lanRuntime()
        try rt.handle(.setRunning(false))
        let v = rt.snapshot().version
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().version == v)
        try rt.handle(.rename(id: "a", name: "X"))
        #expect(rt.snapshot().version == v + 1)
    }

    @Test func listsEventsAndDecodesTheirPduHeaderByHeader() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 500)
        let events = rt.events(from: 0)
        #expect(events.map(\.id) == Array(0..<events.count))
        #expect(events[0].info == "Chi ha 10.0.0.2? Rispondi a 10.0.0.1" && events[0].bytes == 42)
        let echo = try #require(events.first { $0.proto == .icmp && $0.kind == .tx && $0.node == "a" })
        #expect(echo.info.hasPrefix("10.0.0.1 → 10.0.0.2 Echo request id=") && echo.info.hasSuffix(" seq=1 ttl=64"))
        #expect(echo.bytes == 98)
        let pdu = try #require(rt.pdu(echo.id))
        #expect(pdu.map(\.title) == ["Ethernet II", "IPv4", "ICMP"])
        #expect(pdu.map(\.bytes) == [98, 84, 64])
        let ip = Dictionary(uniqueKeysWithValues: pdu[1].fields.map { ($0.name, $0.value) })
        #expect(ip["TTL"] == "64" && ip["Protocollo"] == "1 (ICMP)" && ip["Lunghezza totale"] == "84 B" && ip["Flag"] == "0x2 (DF)")
        #expect(ip["Checksum header"]?.count == 6)
        #expect(pdu[2].fields.first == PduField(name: "Tipo", value: "8 (Echo request)"))
        #expect(rt.events(from: 0, limit: 2).map(\.id) == Array(events.suffix(2).map(\.id)))
        #expect(rt.pdu(1_000_000) == nil)
    }

    @Test func linkOptionsAndStateAreValidatedAppliedAndReported() throws {
        let rt = try lanRuntime()
        try rt.handle(.updateLink(id: "l1", options: LinkOptions(bandwidthBps: 10e6, propDelayNs: 2_000)))
        #expect(rt.snapshot().links[0].options == LinkOptions(bandwidthBps: 10e6, propDelayNs: 2_000))
        expectError("loss rate") { try rt.handle(.updateLink(id: "l1", options: LinkOptions(lossRate: 3))) }
        expectError("Unknown link") { try rt.handle(.setLinkUp(id: "zz", up: false)) }
        try rt.handle(.setLinkUp(id: "l2", up: false))
        #expect(rt.snapshot().links.map(\.up) == [true, false])
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 15_000)
        #expect(rt.snapshot().apps[0].lines.last?.hasSuffix("100% packet loss") == true)
    }

    @Test func poweringOffStopsAppsForgetsTablesAndRefusesNewApps() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 1_500)
        #expect(rt.snapshot().nodes[0].arp.count == 1 && rt.snapshot().nodes[2].mac.count == 2)
        try rt.handle(.setPower(id: "a", on: false))
        try rt.handle(.setPower(id: "s", on: false))
        let s = rt.snapshot()
        #expect(!s.nodes[0].powered && s.nodes[0].arp.isEmpty && s.apps[0].done && s.nodes[2].mac.isEmpty)
        expectError("powered off") { try rt.handle(.ping(node: "a", target: "10.0.0.2")) }
        try rt.handle(.setPower(id: "a", on: true))
        #expect(rt.snapshot().nodes[0].powered)
    }

    @Test func loadRestoresLinkOptionsLinkStateAndPower() throws {
        let rt = Runtime()
        let opts = LinkOptions(bandwidthBps: 1e6, propDelayNs: 10_000, lossRate: 0.1, queueLimit: 5)
        let t = Topology(nodes: [
            TopologyNode(id: "a", kind: .pc, name: "PC1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: nil)], routes: [], powered: false),
            TopologyNode(id: "b", kind: .pc, name: "PC2", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: nil)], routes: []),
        ], links: [LinkView(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "b", iface: "eth0"), options: opts, up: false)])
        try rt.handle(.load(t))
        let s = rt.snapshot()
        #expect(s.links == t.links)
        #expect(s.nodes.map(\.powered) == [false, true])
        #expect(s.epoch == 1)
        var bad = t
        bad.links[0].options.lossRate = 7
        expectError("loss rate") { try rt.handle(.load(bad)) }
        #expect(rt.snapshot().links == t.links)
    }

    @Test func decodesFilesWithoutLinkOptionsOrPower() throws {
        let json = #"""
        {"version":1,"seed":1,"links":[{"id":"l","a":{"node":"a","iface":"eth0"},"b":{"node":"b","iface":"eth0"}}],
         "nodes":[{"id":"a","kind":"pc","name":"PC1","pos":{"x":0,"y":0},"ifaces":[{"name":"eth0"}],"routes":[]}]}
        """#
        let t = try JSONDecoder().decode(Topology.self, from: Data(json.utf8))
        #expect(t.links[0].options == LinkOptions() && t.links[0].up)
        #expect(t.nodes[0].powered)
    }

    @Test func reportsAnL2LoopAsAWarningAndBoundsTheWorkPerTick() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "s1", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "s2", kind: .switch, name: "SW2"))
        try rt.handle(.connect(id: "x", a: IfaceRef(node: "s1", iface: "Gi0/1"), b: IfaceRef(node: "s2", iface: "Gi0/1")))
        try rt.handle(.connect(id: "y", a: IfaceRef(node: "s1", iface: "Gi0/2"), b: IfaceRef(node: "s2", iface: "Gi0/2")))
        try rt.handle(.connect(id: "z", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s1", iface: "Gi0/3")))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.ping(node: "a", target: "10.0.0.9"))
        runFor(rt, wallMs: 300)
        let s = rt.snapshot()
        #expect(Set(s.warnings.map(\.node)) == ["s1", "s2"])
        #expect(s.timeNs < 300_000_000) // the storm hit the per-tick budget: simulated time fell behind
        #expect(rt.events(from: 0).count == 5000)
    }
}
