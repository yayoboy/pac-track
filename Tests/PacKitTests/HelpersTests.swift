import CoreGraphics
import PacEngine
import Testing
@testable import PacKit

@Suite struct HelpersTests {
    private func snapshot() throws -> Snapshot {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "c", kind: .pc, name: "PC3"))
        try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "r", iface: "Gi0/0"), b: IfaceRef(node: "a", iface: "eth0")))
        try rt.handle(.setIp(node: "r", iface: "Gi0/1", cidr: "10.0.0.1/24"))
        try rt.handle(.addRoute(node: "r", cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        return rt.snapshot()
    }

    @Test func printersAndTvsAreHostsWithItalianNamesAndTabs() {
        #expect([DeviceKind.printer, .tv].map(\.label) == ["Stampante", "Smart TV"])
        #expect(defaultName(.printer, taken: ["PRN1"]) == "PRN2" && defaultName(.tv, taken: []) == "TV1")
        #expect(DeviceKind.printer.isHost && DeviceKind.tv.isHost && DeviceKind.printer.hasIp)
        #expect(inspectorTabs(for: .printer) == [.interfaces, .routing, .services, .tables, .app])
        #expect(inspectorTabs(for: .tv) == [.interfaces, .routing, .tables, .app])
        #expect(inspectorTabs(for: .pc) == [.interfaces, .routing, .wifi, .tables, .app]) // the Wi-Fi tab since M11
    }

    @Test func picksTheLowestFreeDefaultNamePerKind() throws {
        let nodes = try snapshot().nodes
        #expect(defaultName(.pc, existing: nodes) == "PC2")
        #expect(defaultName(.router, existing: nodes) == "R2")
        #expect(defaultName(.switch, existing: nodes) == "SW1")
    }

    @Test func findsFreePortsFirstIpAndGateway() throws {
        let nodes = try snapshot().nodes
        let r = nodes[2]
        #expect(firstFreeIface(r) == "Gi0/1")
        #expect(firstIp(r) == "10.0.0.1")
        #expect(gatewayOf(r) == "10.0.0.254")
        #expect(firstFreeIface(nodes[0]) == nil)
    }

    @Test func namesTheDeviceAndPortAtTheOtherEndOfTheCable() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "r", iface: "Gi0/0"), b: IfaceRef(node: "a", iface: "eth0")))
        try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.10"))
        let s = rt.snapshot()
        #expect(peerLabel(IfaceRef(node: "a", iface: "eth0"), in: s) == "R1 Gi0/0")
        #expect(peerLabel(IfaceRef(node: "r", iface: "Gi0/0"), in: s) == "PC1 eth0")
        #expect(peerLabel(IfaceRef(node: "r", iface: "Gi0/0.10"), in: s) == "PC1 eth0") // rides on its physical interface's cable
        #expect(peerLabel(IfaceRef(node: "r", iface: "Gi0/1"), in: s) == nil)
    }

    @Test func suggestsFreeAddressesAndGatewaysFromTheSegment() throws {
        let rt = Runtime()
        for (id, kind, name) in [("a", DeviceKind.pc, "PC1"), ("b", .pc, "PC2"), ("c", .pc, "PC3"), ("d", .pc, "PC4"), ("v", .server, "SRV1"),
                                 ("s", .switch, "SW1"), ("r", .router, "R1")] {
            try rt.handle(.addNode(id: id, kind: kind, name: name))
        }
        for (id, a, ai, b, bi) in [("1", "a", "eth0", "s", "Gi0/1"), ("2", "b", "eth0", "s", "Gi0/2"), ("3", "v", "eth0", "s", "Gi0/3"),
                                   ("4", "r", "Gi0/0", "s", "Gi0/4"), ("5", "c", "eth0", "r", "Gi0/1")] {
            try rt.handle(.connect(id: id, a: IfaceRef(node: a, iface: ai), b: IfaceRef(node: b, iface: bi)))
        }
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "192.168.1.10/24"))
        try rt.handle(.setIp(node: "r", iface: "Gi0/0", cidr: "192.168.1.1/24"))
        try rt.handle(.setIp(node: "r", iface: "Gi0/1", cidr: "10.0.0.1/30"))
        try rt.handle(.setIp(node: "v", iface: "eth0", cidr: "192.168.1.2/24"))
        try rt.handle(.setDhcpServer(node: "v", config: DhcpConfig(start: "192.168.1.3", end: "192.168.1.9")))
        let s = rt.snapshot()
        let address = { (node: String) in addressSuggestions(IfaceRef(node: node, iface: "eth0"), in: s) }
        #expect(address("b") == ["192.168.1.11/24", "192.168.1.12/24", "192.168.1.13/24"]) // past R1, SRV1, the pool and PC1
        #expect(address("v") == ["192.168.1.11/24", "192.168.1.12/24", "192.168.1.13/24"]) // SRV1 skips its own pool too
        #expect(address("c") == ["10.0.0.2/30"]) // the only host left; .3 is the broadcast
        #expect(address("d").isEmpty) // nothing on its segment
        #expect(gatewaySuggestions("b", in: s) == ["192.168.1.1"]) // routers only, not SRV1 or PC1
        #expect(gatewaySuggestions("c", in: s) == ["10.0.0.1"])
        #expect(gatewaySuggestions("d", in: s).isEmpty)
    }

    @Test func comparesTopologiesIgnoringPositions() throws {
        let s = try snapshot()
        let a = makeTopology(s, [:])
        let moved = makeTopology(s, ["a": Pos(x: 9, y: 9)])
        var renamed = a
        renamed.nodes[0].name = "X"
        #expect(sameNetwork(a, moved))
        #expect(!sameNetwork(a, renamed))
        #expect(positions(of: moved)["a"] == Pos(x: 9, y: 9))
    }

    @Test func snapsToTheGrid() {
        #expect(snap(Pos(x: 20, y: 6)) == Pos(x: 14, y: 0))
        #expect(snap(Pos(x: 22, y: -8)) == Pos(x: 28, y: -14))
    }

    @Test func formatsSimulatedTimeToTheNanosecond() {
        #expect(formatSimTime(0) == "0.000000000 s")
        #expect(formatSimTime(1_000_002_672) == "1.000002672 s")
    }

    @Test func filtersEventsByProtocolAndNode() {
        let e = { (id: Int, node: String, p: Proto) in
            EventView(id: id, timeNs: 0, kind: .tx, node: node, iface: "eth0", proto: p, frameId: id, bytes: 42, info: "", reason: nil)
        }
        let all = [e(0, "a", .arp), e(1, "b", .icmp), e(2, "a", .icmp)]
        #expect(filterEvents(all, protos: [.icmp], node: nil).map(\.id) == [1, 2])
        #expect(filterEvents(all, protos: Set(Proto.allCases), node: "a").map(\.id) == [0, 2])
    }

    @Test func animatesAFrameFromTxUntilItArrivesAndForAtLeastTheFlightTime() {
        let links = [LinkView(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "b", iface: "eth0"))]
        let tx = EventView(id: 0, timeNs: 0, kind: .tx, node: "a", iface: "eth0", proto: .icmp, frameId: 7, bytes: 98, info: "", reason: nil)
        let rx = EventView(id: 1, timeNs: 1172, kind: .rx, node: "b", iface: "eth0", proto: .icmp, frameId: 7, bytes: 98, info: "", reason: nil)
        var f = updateFlights([], with: [tx], links: links, now: 0)
        #expect(f.map(\.from) == ["a"] && !f[0].arrived)
        #expect(flightProgress(f[0], now: 0.2) == 0.5)
        #expect(flightProgress(f[0], now: 9) == 1)
        #expect(pruneFlights(f, links: links, now: 0.7).count == 1) // still on the wire: waits for the next step
        #expect(pruneFlights(f, links: links, now: 0.8).isEmpty) // its rx never came (pull cap, evicted): do not animate forever
        f = updateFlights(f, with: [rx], links: links, now: 0.1)
        #expect(f.count == 1 && f[0].arrived)
        #expect(pruneFlights(f, links: links, now: 0.5).isEmpty)
        #expect(pruneFlights(f, links: [], now: 0.1).isEmpty) // cable removed
    }

    /// Spec M11 §7: PDUs fly along the dashed line; a frame from the access point's radio is drawn when a station receives it.
    @Test func flightsCrossTheAirFromAndToTheStations() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "ap", kind: .accessPoint, name: "AP1"))
        for id in ["t", "s"] {
            try rt.handle(.addNode(id: id, kind: .tablet, name: id))
            try rt.handle(.setStation(node: id, config: StationConfig(ssid: "pac-track")))
        }
        for _ in 0..<2 { rt.advance(wallMs: 100) }
        let air = airLinks(rt.snapshot().nodes)
        #expect(air == ["t", "s"].map { LinkView(id: "air:\($0)", a: IfaceRef(node: $0, iface: "wlan0"), b: IfaceRef(node: "ap", iface: "Dot11Radio0")) })
        let ev = { (id: Int, kind: EventKind, node: String, iface: String) in
            EventView(id: id, timeNs: 0, kind: kind, node: node, iface: iface, proto: .icmp, frameId: 7, bytes: 116, info: "", reason: nil)
        }
        var f = updateFlights([], with: [ev(1, .tx, "t", "wlan0")], links: air, now: 0)
        #expect(f.map { "\($0.link) \($0.from) \($0.arrived)" } == ["air:t t false"])
        f = updateFlights(f, with: [ev(2, .rx, "ap", "Dot11Radio0"), ev(3, .tx, "ap", "Dot11Radio0"), ev(4, .rx, "s", "wlan0")], links: air, now: 0.1)
        #expect(f.map { "\($0.link) \($0.from) \($0.arrived)" } == ["air:t t true", "air:s ap true"])
    }

    @Test func parsesAndFormatsLinkFields() throws {
        let o = LinkOptions()
        #expect(LinkField.allCases.map { $0.format(o) } == ["1000", "0.5", "0", "1000"])
        #expect(try LinkField.bandwidth.apply(" 0,1 ", to: o).bandwidthBps == 100_000)
        #expect(try LinkField.delay.apply("2.5", to: o).propDelayNs == 2_500)
        #expect(abs(try LinkField.loss.apply("1.1", to: o).lossRate - 0.011) < 1e-12)
        #expect(LinkField.loss.format(try LinkField.loss.apply("1.1", to: o)) == "1.1")
        for bad in ["abc", "", "nan", "inf", "1e300"] {
            expectError("Invalid number") { _ = try LinkField.delay.apply(bad, to: o) }
        }
        expectError("Invalid number") { _ = try LinkField.queue.apply("2.5", to: o) }
    }

    @Test func formatsBandwidthWithUnits() {
        #expect(formatBandwidth(1e9) == "1 Gb/s")
        #expect(formatBandwidth(10e6) == "10 Mb/s")
        #expect(formatBandwidth(1_500) == "1.5 kb/s")
        #expect(formatBandwidth(64) == "64 b/s")
    }

    @Test func formatsTheLatestFlowAndCableMetrics() {
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 9_492_848, delayNs: 1_234_567, jitterNs: nil, lossPct: 1.5))
            == "9.49 Mb/s · RTT 1.235 ms · perdita 1.5%")
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 1_011_360, delayNs: 1_229_300, jitterNs: 2_600, lossPct: 0))
            == "1.01 Mb/s · latenza 1.229 ms · jitter 0.003 ms · perdita 0.0%")
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 0, delayNs: nil, jitterNs: nil, lossPct: 0)) == "0.00 Mb/s · perdita 0.0%")
        #expect(directionSummary(DirectionSample(utilization: 0.946, queued: 12, drops: 3)) == "95% · coda 12 · drop 3")
    }

    @Test func exportFramesEveryDeviceBoxWithAMargin() {
        #expect(exportBounds([], nodeSize: CGSize(width: 104, height: 46), margin: 40) == nil)
        let r = exportBounds([Pos(x: 100, y: 100), Pos(x: 300, y: 200)], nodeSize: CGSize(width: 104, height: 46), margin: 40)
        #expect(r == CGRect(x: 8, y: 37, width: 384, height: 226))
    }

    @Test func cableEndsShowTheLeastAdvancedStpStateOfTheirPort() throws {
        let rt = Runtime()
        for (id, name) in [("s1", "SW1"), ("s2", "SW2")] { try rt.handle(.addNode(id: id, kind: .switch, name: name)) }
        for (id, port) in [("x", "Gi0/1"), ("y", "Gi0/2")] {
            try rt.handle(.connect(id: id, a: IfaceRef(node: "s1", iface: port), b: IfaceRef(node: "s2", iface: port)))
        }
        rt.advance(wallMs: 100)
        let dot = { (node: String, port: String) in stpDot(IfaceRef(node: node, iface: port), in: rt.snapshot().nodes) }
        #expect(dot("s1", "Gi0/1") == .listening && dot("s2", "Gi0/2") == .blocking)
        for _ in 0..<300 { rt.advance(wallMs: 100) }
        #expect(dot("s1", "Gi0/1") == nil && dot("s2", "Gi0/1") == nil && dot("s2", "Gi0/2") == .blocking)
        #expect(EventKind.state.label == "STATO")
    }

    @Test func parallelCablesBetweenTheSameDevicesGetSymmetricSlots() {
        let cable = { (id: String, a: String, b: String) in LinkView(id: id, a: IfaceRef(node: a, iface: "x"), b: IfaceRef(node: b, iface: "y")) }
        let links = [cable("1", "s1", "s2"), cable("2", "s1", "p"), cable("3", "s2", "s1"), cable("4", "s1", "s2")]
        #expect(links.map { cableSlot($0, in: links) } == [-1, 0, 0, 1])
    }

    /// Spec M11 §3: management frames get their own chip, named after the standard.
    @Test func theWifiChipReads80211() {
        #expect(Proto.wifi.label == "802.11" && Proto.ndp.label == "NDP")
    }

    @Test func wirelessDevicesHaveItalianNamesAndOnlyTheClientsAreHosts() {
        #expect([DeviceKind.accessPoint, .tablet, .smartphone].map(\.label) == ["Access point", "Tablet", "Smartphone"])
        #expect(defaultName(.accessPoint, taken: ["AP1"]) == "AP2" && defaultName(.tablet, taken: []) == "TAB1"
            && defaultName(.smartphone, taken: []) == "PHONE1")
        #expect(DeviceKind.tablet.isHost && DeviceKind.smartphone.isHost && !DeviceKind.accessPoint.isHost && !DeviceKind.accessPoint.hasIp)
    }

    /// Spec M11 §7: the Wi-Fi tab and its status line, Tabelle's Wi-Fi row and the access point's clients; no cable from a tablet.
    @Test func theWifiTabTablesAndStatus() throws {
        #expect(inspectorTabs(for: .accessPoint) == [.wifi, .tables])
        #expect(inspectorTabs(for: .tablet) == [.interfaces, .routing, .wifi, .tables, .app] && inspectorTabs(for: .smartphone) == inspectorTabs(for: .tablet))
        let rt = Runtime()
        try rt.handle(.addNode(id: "ap", kind: .accessPoint, name: "AP1"))
        try rt.handle(.addNode(id: "t", kind: .tablet, name: "TAB1"))
        try rt.handle(.addNode(id: "x", kind: .tablet, name: "TAB2"))
        try rt.handle(.setStation(node: "t", config: StationConfig(ssid: "pac-track")))
        try rt.handle(.setStation(node: "x", config: StationConfig(ssid: "altrove")))
        #expect(wifiStatus(rt.snapshot().nodes[1].station!, in: rt.snapshot().nodes) == "Scansione…")
        for _ in 0..<2 { rt.advance(wallMs: 100) }
        let nodes = rt.snapshot().nodes
        #expect(wifiStatus(nodes[1].station!, in: nodes) == "Associato a pac-track · AP1 · canale 6")
        #expect(wifiStatus(nodes[2].station!, in: nodes) == "Nessuna rete trovata")
        #expect(wifiRow(nodes[1].station!) == ["associato", "pac-track", nodes[0].ifaces[1].mac, "6"])
        #expect(wifiRow(nodes[2].station!) == ["nessuna rete trovata", "altrove", "-", "-"])
        #expect(associationRows(nodes[0].accessPoint!, in: nodes) == [["1", nodes[1].ifaces[0].mac, "TAB1"]])
        #expect(firstFreeIface(nodes[1]) == nil && firstFreeIface(nodes[0]) == "Gi0")
    }
}
