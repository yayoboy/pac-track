import Testing
@testable import PacEngine

/// AP1 (pac-track, channel 6) at the origin and TAB1 at (x, 0) looking for pac-track; it starts scanning at once.
private func pair(at x: Double) throws -> (sim: Sim, ap: AccessPoint, tab: Host) {
    let sim = Sim()
    let ap = AccessPoint(sim: sim, id: "AP1")
    let tab = Host(sim: sim, id: "TAB1", wifi: true)
    tab.pos = Pos(x: x, y: 0)
    try tab.station!.configure(StationConfig(ssid: "pac-track"))
    return (sim, ap, tab)
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct WifiRangeTests {
    /// Spec M11 §8: −30 dBm next to the access point, −82 dBm (the 6 Mb/s sensitivity) at the edge of its 300-point range, linear in
    /// dB; the rate is the highest whose minimum sensitivity the signal reaches (IEEE 802.11-2016 Table 17-18).
    @Test func signalAndRateFallWithDistance() {
        let sim = Sim()
        let a = Probe(sim: sim, id: "A")
        let b = Probe(sim: sim, id: "B")
        let signals = [0.0, 150, 200, 270, 300, 301].map { x -> Int? in
            b.pos = Pos(x: x, y: 0)
            return dot11Signal(a, b)
        }
        #expect(signals == [-30, -56, -65, -77, -82, nil])
        a.pos = Pos(x: 180, y: 240) // 300 pt from the origin, diagonally
        b.pos = Pos(x: 0, y: 0)
        #expect(dot11Signal(a, b) == -82)
        #expect([-30, -65, -66, -70, -74, -77, -79, -81, -82].map { dot11Rate(signal: $0) } == [54, 54, 48, 36, 24, 18, 12, 9, 6])
    }

    /// Spec M11 §8: beyond the range the two radios do not hear each other at all.
    @Test func aStationOutOfRangeNeverHearsTheAccessPoint() throws {
        let (sim, _, tab) = try pair(at: 301)
        sim.run(6 * S)
        #expect(tab.station!.state == .notFound)
        #expect(sim.log.all.filter { $0.kind == .rx }.isEmpty)
    }

    /// Spec M11 §8: unicast data both ways at the station's rate (270 pt: −77 dBm, 18 Mb/s) with the ACK at 12; management and group
    /// frames stay at 6.
    @Test func unicastDataGoesAtTheStationsRate() throws {
        let (sim, ap, tab) = try pair(at: 270)
        let srv = Host(sim: sim, id: "SRV")
        _ = try Link(sim: sim, try srv.iface("eth0"), try ap.iface("Gi0"))
        sim.run(100 * MS)
        try tab.setIp("wlan0", "10.0.0.1/24")
        try srv.setIp("eth0", "10.0.0.100/24")
        tab.sendPacket(try parseIp("10.0.0.100"), echoRequest())
        sim.run(100 * MS)
        let onAir = sim.log.all.filter { $0.kind == .tx && $0.frame?.air != nil }.compactMap(\.frame)
        let icmp = onAir.filter { if case .ipv4 = $0.payload { true } else { false } }
        #expect(icmp.count == 2 && icmp.allSatisfy { $0.air?.rate == 18 })
        let request = icmp[0]
        #expect(dot11Airtime(request).frame == DOT11_DIFS_US + DOT11_BACKOFF_US + dot11TxUs(bytes: request.size + 4, rateMbps: 18))
        #expect(dot11Airtime(request).ack == DOT11_SIFS_US + dot11TxUs(bytes: DOT11_ACK_BYTES, rateMbps: 12))
        let mgmt = onAir.filter { if case .mgmt = $0.payload { true } else { false } }
        #expect(!mgmt.isEmpty && mgmt.allSatisfy { $0.air?.rate == 6 })
        // The ARP request is a group frame on its way out of the access point.
        let relayed = onAir.first { $0.dst == BROADCAST_MAC && $0.air?.fromDS == true }
        #expect(relayed?.air?.rate == 6)
    }

    /// Spec M11 §8: of the access points with its SSID the station picks the strongest, not the first that answered.
    @Test func theStationPicksTheStrongestAccessPoint() throws {
        let sim = Sim()
        let far = AccessPoint(sim: sim, id: "AP1")
        try far.radio.configure(ApConfig(ssid: "pac-track", channel: 1))
        far.pos = Pos(x: 250, y: 0)
        let near = AccessPoint(sim: sim, id: "AP2")
        try near.radio.configure(ApConfig(ssid: "pac-track", channel: 11))
        near.pos = Pos(x: 0, y: 50)
        let tab = Host(sim: sim, id: "TAB1", wifi: true)
        try tab.station!.configure(StationConfig(ssid: "pac-track"))
        sim.run(100 * MS)
        #expect(tab.station!.state == .associated && tab.station!.ap === near.radio && tab.station!.channel == 11)
        #expect(far.radio.clients.isEmpty)
    }

    /// Spec M11 §8: a move out of range ends the association at once, without a frame; back in range the next scan finds the access
    /// point again. The snapshot shows signal and rate of an association.
    @Test func movingOutOfRangeDropsTheAssociationAndComingBackRestoresIt() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "ap", kind: .accessPoint, name: "AP1"))
        try rt.handle(.addNode(id: "t", kind: .tablet, name: "TAB1"))
        try rt.handle(.move(node: "t", to: Pos(x: 270, y: 0)))
        try rt.handle(.setStation(node: "t", config: StationConfig(ssid: "pac-track")))
        runFor(rt, wallMs: 200)
        var s = rt.snapshot()
        let radio = s.nodes[0].ifaces[1].mac
        #expect(s.nodes[1].station == StationView(config: StationConfig(ssid: "pac-track"), state: .associated, bssid: radio, ap: "ap",
                                                  channel: 6, signal: -77, rate: 18))
        #expect(s.nodes[0].accessPoint?.clients == [AssociationRow(aid: 1, mac: s.nodes[1].ifaces[0].mac, node: "t", signal: -77, rate: 18)])
        let events = s.eventCount
        try rt.handle(.move(node: "t", to: Pos(x: 310, y: 0)))
        s = rt.snapshot()
        #expect(s.nodes[1].station?.state == .scanning && s.nodes[1].station?.signal == nil && s.nodes[0].accessPoint?.clients == [])
        #expect(s.eventCount == events)
        runFor(rt, wallMs: 1000)
        #expect(rt.snapshot().nodes[1].station?.state == .notFound)
        try rt.handle(.move(node: "ap", to: Pos(x: 250, y: 0)))
        runFor(rt, wallMs: 5000)
        #expect(rt.snapshot().nodes[1].station?.state == .associated && rt.snapshot().nodes[1].station?.rate == 54)
        expectError("Unknown node x") { try rt.handle(.move(node: "x", to: Pos(x: 0, y: 0))) }
    }

    /// Spec M11 §8, §10: positions come back from the file into the engine.
    @Test func positionsComeBackFromTheProjectFile() throws {
        let t = Topology(nodes: [
            TopologyNode(id: "ap", kind: .accessPoint, name: "AP1", pos: Pos(x: 0, y: 0),
                         ifaces: [TopologyIface(name: "Gi0", cidr: nil), TopologyIface(name: "Dot11Radio0", cidr: nil)], routes: [],
                         accessPoint: ApConfig()),
            TopologyNode(id: "t", kind: .tablet, name: "TAB1", pos: Pos(x: 0, y: 400), ifaces: [TopologyIface(name: "wlan0", cidr: nil)],
                         routes: [], station: StationConfig(ssid: "pac-track")),
            TopologyNode(id: "s", kind: .smartphone, name: "PHONE1", pos: Pos(x: 0, y: 200), ifaces: [TopologyIface(name: "wlan0", cidr: nil)],
                         routes: [], station: StationConfig(ssid: "pac-track")),
        ])
        let rt = Runtime()
        try rt.handle(.load(t))
        runFor(rt, wallMs: 200)
        #expect(rt.snapshot().nodes.dropFirst().map { $0.station?.state } == [.notFound, .associated])
    }
}
