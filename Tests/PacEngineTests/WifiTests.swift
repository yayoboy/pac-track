import Testing
@testable import PacEngine

/// AP1 (pac-track, channel 6) and Wi-Fi hosts looking for `ssid`; they start scanning at once.
private func cell(_ names: [String] = ["TAB1"], ssid: String = "pac-track") throws -> (sim: Sim, ap: AccessPoint, stations: [Host]) {
    let sim = Sim()
    let ap = AccessPoint(sim: sim, id: "AP1")
    let stations = try names.map { name in
        let h = Host(sim: sim, id: name, wifi: true)
        try h.station!.configure(StationConfig(ssid: ssid))
        return h
    }
    return (sim, ap, stations)
}

private func isMgmt(_ e: SimEvent) -> Bool {
    if case .mgmt? = e.frame?.payload { true } else { false }
}

/// "<µs> <tx|rx> <node> <info>" for each 802.11 management event, in order.
private func mgmtLog(_ sim: Sim) -> [String] {
    sim.log.all.filter(isMgmt).map { "\($0.time / US) \($0.kind.rawValue) \($0.node) \(eventView($0).info)" }
}

/// AP1 with SRV (10.0.0.100) on its cable, TAB1 (10.0.0.1) and PHONE1 (10.0.0.2) associated; at 100 ms.
private func wlan() throws -> (sim: Sim, ap: AccessPoint, srv: Host, tab: Host, phone: Host) {
    let (sim, ap, st) = try cell(["TAB1", "PHONE1"])
    let srv = Host(sim: sim, id: "SRV")
    _ = try Link(sim: sim, try srv.iface("eth0"), try ap.iface("Gi0"))
    sim.run(100 * MS)
    try st[0].setIp("wlan0", "10.0.0.1/24")
    try st[1].setIp("wlan0", "10.0.0.2/24")
    try srv.setIp("eth0", "10.0.0.100/24")
    return (sim, ap, srv, st[0], st[1])
}

/// Where one frame went: "tx TAB1 wlan0", "rx AP1 Dot11Radio0"…
private func hops(_ sim: Sim, _ frame: Int) -> [String] {
    sim.log.all.filter { $0.frame?.id == frame }.map { "\($0.kind.rawValue) \($0.node) \($0.iface ?? "")" }
}

private func isEchoRequest(_ e: SimEvent, seq: UInt16) -> Bool {
    guard case .ipv4(let p)? = e.frame?.payload, case .icmp(let m) = p.payload else { return false }
    return m.type == ICMP_ECHO_REQUEST && m.seq == seq
}

/// UDP payload bits per second the medium carries: one 1470-byte datagram per 389 µs.
private let WIFI_GOODPUT = 1470.0 * 8 / 389e-6

@Suite struct WifiTests {
    /// Spec M11 §5: a Probe Request on 1, 6 and 11, 20 ms each; AP1 answers on 6; after the scan Open System authentication and
    /// association, each frame holding the medium for DIFS + backoff + frame (+ SIFS + ACK when unicast).
    @Test func aStationScansTheThreeChannelsAndAssociatesWithTheAccessPointThatAnswered() throws {
        let (sim, ap, st) = try cell()
        let tab = st[0]
        #expect(tab.station!.state == .scanning && !tab.nic.lineUp)
        sim.run(100 * MS)
        #expect(mgmtLog(sim) == [
            "0 tx TAB1 Probe Request, SSID=pac-track",
            "20000 tx TAB1 Probe Request, SSID=pac-track",
            "20189 rx AP1 Probe Request, SSID=pac-track",
            "20189 tx AP1 Probe Response, SSID=pac-track, canale 6",
            "20398 rx TAB1 Probe Response, SSID=pac-track, canale 6",
            "40000 tx TAB1 Probe Request, SSID=pac-track",
            "60000 tx TAB1 Authentication, Open System, transazione 1",
            "60169 rx AP1 Authentication, Open System, transazione 1",
            "60229 tx AP1 Authentication, Open System, transazione 2, stato 0",
            "60398 rx TAB1 Authentication, Open System, transazione 2, stato 0",
            "60458 tx TAB1 Association Request, SSID=pac-track",
            "60651 rx AP1 Association Request, SSID=pac-track",
            "60711 tx AP1 Association Response, stato 0, AID=1",
            "60892 rx TAB1 Association Response, stato 0, AID=1",
        ])
        let seqs = { (node: String) in sim.log.all.filter { $0.kind == .tx && $0.node == node }.compactMap { $0.frame?.air?.seq } }
        #expect(seqs("TAB1") == [0, 1, 2, 3, 4] && seqs("AP1") == [0, 1, 2])
        let response = sim.log.all.first { $0.kind == .tx && $0.node == "AP1" }!.frame!
        #expect(response.payload == .mgmt(.probeResponse(ssid: "pac-track", channel: 6, timestamp: 20_189)))
        #expect(response.air?.bssid == ap.radio.iface.mac && response.dst == tab.nic.mac)
        #expect(tab.station!.state == .associated && tab.station!.ap === ap.radio && tab.station!.channel == 6 && tab.nic.lineUp)
        #expect(ap.radio.clients.map { "\($0.aid) \($0.station.iface.node.id)" } == ["1 TAB1"] && ap.radio.lineUp)
    }

    /// AIDs from 1 in the order the access point associates; the same network gives the same air (spec M11 §4: FIFO medium).
    @Test func stationsGetAidsInTheOrderTheyAssociateAndRunsRepeat() throws {
        let (sim, ap, _) = try cell(["TAB1", "PHONE1"])
        sim.run(100 * MS)
        #expect(ap.radio.clients.map { "\($0.aid) \($0.station.iface.node.id)" } == ["1 TAB1", "2 PHONE1"])
        let (again, _, _) = try cell(["TAB1", "PHONE1"])
        again.run(100 * MS)
        #expect(mgmtLog(again) == mgmtLog(sim) && mgmtLog(sim).count > 20)
    }

    /// Spec M11 §5: no answer, "Nessuna rete trovata", and a new scan 5 s later finds an access point switched on meanwhile.
    @Test func withoutAnAnswerTheStationScansAgainEveryFiveSeconds() throws {
        let sim = Sim()
        let tab = Host(sim: sim, id: "TAB1", wifi: true)
        try tab.station!.configure(StationConfig(ssid: "pac-track"))
        sim.run(100 * MS)
        #expect(tab.station!.state == .notFound)
        _ = AccessPoint(sim: sim, id: "AP1")
        sim.run(5_100 * MS)
        let probes = sim.log.all.filter { $0.kind == .tx && $0.node == "TAB1" && $0.frame?.payload == .mgmt(.probeRequest(ssid: "pac-track")) }
        #expect(probes.map { $0.time / US } == [0, 20_000, 40_000, 5_060_000, 5_080_000, 5_100_000])
        #expect(mgmtLog(sim).last == "5120892 rx TAB1 Association Response, stato 0, AID=1" && tab.station!.state == .associated)
    }

    /// Spec M11 §5: a new SSID on the access point is a group Deauthentication (reason 3) and the stations scan again; a new network
    /// on the station is a Deauthentication to its access point.
    @Test func anSsidChangeEndsTheAssociationWithADeauthentication() throws {
        let (sim, ap, st) = try cell()
        let tab = st[0]
        sim.run(100 * MS)
        try ap.radio.configure(ApConfig(ssid: "lab", channel: 6))
        #expect(ap.radio.clients.isEmpty)
        sim.run(100 * MS)
        #expect(tab.station!.state == .notFound)
        try tab.station!.configure(StationConfig(ssid: "lab"))
        sim.run(100 * MS)
        #expect(tab.station!.state == .associated && ap.radio.clients.count == 1)
        try tab.station!.configure(StationConfig(ssid: "other"))
        sim.run(100 * MS)
        #expect(ap.radio.clients.isEmpty && tab.station!.state == .notFound)
        #expect(mgmtLog(sim).filter { $0.contains("Deauthentication") } == [
            "100000 tx AP1 Deauthentication, motivo 3", "100161 rx TAB1 Deauthentication, motivo 3",
            "300000 tx TAB1 Deauthentication, motivo 3", "300161 rx AP1 Deauthentication, motivo 3",
        ])
        let deauths = sim.log.all.filter { $0.kind == .tx && $0.frame?.payload == .mgmt(.deauthentication(reason: 3)) }.map { $0.frame!.dst }
        #expect(deauths == [BROADCAST_MAC, ap.radio.iface.mac])
        expectError("SSID must be 1 to 32 bytes") { try ap.radio.configure(ApConfig(ssid: "", channel: 6)) }
        expectError("Channel must be 1, 6 or 11") { try ap.radio.configure(ApConfig(ssid: "lab", channel: 3)) }
        expectError("SSID must be at most 32 bytes") { try tab.station!.configure(StationConfig(ssid: String(repeating: "è", count: 17))) }
    }

    /// Spec M11 §5: an access point or a station switched off (or removed) ends the association at once, without a frame; the
    /// station scans again and finds the access point back on at its next scan.
    @Test func switchingEitherSideOffEndsTheAssociationAtOnce() throws {
        let (sim, ap, st) = try cell()
        let tab = st[0]
        sim.run(100 * MS)
        let frames = sim.log.total
        ap.powered = false
        ap.reset()
        #expect(tab.station!.state == .scanning && !tab.nic.lineUp && ap.radio.clients.isEmpty && sim.log.total == frames)
        sim.run(100 * MS)
        #expect(tab.station!.state == .notFound)
        ap.powered = true
        ap.powerOn()
        sim.run(5_100 * MS) // the next scan starts at 5.16 s
        #expect(tab.station!.state == .associated)
        tab.powered = false
        tab.reset()
        #expect(ap.radio.clients.isEmpty && tab.station!.state == .idle && !tab.nic.lineUp)
        tab.powered = true
        tab.powerOn()
        sim.run(100 * MS)
        #expect(tab.station!.state == .associated && ap.radio.clients.count == 1)
    }

    /// Spec M11 §11: no cable on wlan0 or Dot11Radio0; the access point's Gi0 takes one.
    @Test func wirelessInterfacesTakeNoCable() throws {
        let (sim, ap, st) = try cell()
        let sw = Switch(sim: sim, id: "SW1")
        expectError("Cannot cable a wireless interface") { _ = try Link(sim: sim, st[0].nic, try sw.iface("Gi0/1")) }
        expectError("Cannot cable a wireless interface") { _ = try Link(sim: sim, try ap.iface("Dot11Radio0"), try sw.iface("Gi0/2")) }
        _ = try Link(sim: sim, try ap.iface("Gi0"), try sw.iface("Gi0/3"))
        #expect(ap.interfaces.map(\.name) == ["Gi0", "Dot11Radio0"] && st[0].interfaces.map(\.name) == ["wlan0"])
        #expect(Host(sim: sim, id: "PC1").nic.name == "eth0" && Host(sim: sim, id: "PC2").station == nil)
    }

    /// Spec M11 §1, §6: a ping between two stations crosses the air twice each way, never the cable; ARP cached, 4 frames of
    /// 137 µs plus 3 waits of SIFS + ACK.
    @Test func aPingBetweenStationsCrossesTheAirTwiceEachWay() throws {
        let (sim, ap, _, tab, _) = try wlan()
        let p = try Ping(node: tab, target: "10.0.0.2", options: PingOptions(count: 2))
        sim.run(3 * S)
        #expect(p.result.received == 2 && p.result.replies[1].rttNs == 680_000)
        let request = sim.log.all.first { $0.kind == .tx && $0.node == "TAB1" && isEchoRequest($0, seq: 2) }!
        #expect(hops(sim, request.frame!.id) == ["tx TAB1 wlan0", "rx AP1 Dot11Radio0", "tx AP1 Dot11Radio0", "rx PHONE1 wlan0"])
        let relayed = sim.log.all.first { $0.kind == .tx && $0.node == "AP1" && $0.frame?.id == request.frame!.id }!.frame!
        #expect(request.frame!.air == Dot11Header(toDS: true, bssid: ap.radio.iface.mac, seq: request.frame!.air!.seq))
        #expect(relayed.air?.fromDS == true && relayed.air?.toDS == false)
    }

    /// Spec M11 §6: to a MAC on the cable the frame leaves Gi0 with an 802.3 header; a group frame goes to the cable and back on the
    /// air (From DS) to the other stations, never to its sender.
    @Test func theAccessPointBridgesToTheCableAndRelaysGroupFrames() throws {
        let (sim, _, _, tab, _) = try wlan()
        let p = try Ping(node: tab, target: "10.0.0.100", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(p.result.received == 1)
        let arp = sim.log.all.first { if case .arp? = $0.frame?.payload { $0.kind == .tx && $0.node == "TAB1" } else { false } }!
        #expect(hops(sim, arp.frame!.id) == ["tx TAB1 wlan0", "rx AP1 Dot11Radio0", "tx AP1 Gi0", "rx SRV eth0", "tx AP1 Dot11Radio0", "rx PHONE1 wlan0"])
        let request = sim.log.all.first { $0.kind == .tx && $0.node == "TAB1" && isEchoRequest($0, seq: 1) }!
        #expect(hops(sim, request.frame!.id) == ["tx TAB1 wlan0", "rx AP1 Dot11Radio0", "tx AP1 Gi0", "rx SRV eth0"])
        let wired = sim.log.all.first { $0.kind == .tx && $0.iface == "Gi0" && $0.frame?.id == request.frame!.id }!.frame!
        #expect(wired.air == nil && wired.size == 98)
    }

    /// Spec M11 §5: a station that is not associated drops its data frames with `not-associated`.
    @Test func framesOfAStationThatIsNotAssociatedAreDropped() throws {
        let sim = Sim()
        let tab = Host(sim: sim, id: "TAB1", wifi: true)
        try tab.setIp("wlan0", "10.0.0.1/24")
        _ = try Ping(node: tab, target: "10.0.0.2", options: PingOptions(count: 1))
        sim.run(5 * S)
        #expect(drops(sim, .notAssociated) == 3) // the ARP request and its two retries
        #expect(sim.log.all.filter { $0.reason == .notAssociated }.allSatisfy { $0.node == "TAB1" && $0.iface == "wlan0" && $0.frame?.air == nil })
    }

    /// Spec M11 §4: at most 1000 frames wait for the medium per radio; switched off, the radio loses them, and the AP drops the frame
    /// already in the air from a station it forgot.
    @Test func aRadioQueuesAtMost1000FramesAndLosesThemWhenSwitchedOff() throws {
        let (sim, _, _, tab, _) = try wlan()
        let arp = ArpPacket(op: 1, senderMac: tab.nic.mac, senderIp: 0, targetMac: "00:00:00:00:00:00", targetIp: 0)
        for _ in 0..<1002 { tab.sendFrame(tab.nic, to: BROADCAST_MAC, etherType: ETHERTYPE_ARP, .arp(arp)) }
        #expect(drops(sim, .queueFull) == 1 && tab.station!.queued == 1000)
        tab.powered = false
        tab.reset()
        sim.run(10 * MS)
        #expect(drops(sim, .notAssociated) == 1 && drops(sim, .ifaceDown) == 1000 && tab.station!.queued == 0)
    }

    /// Spec M11 §1, §4: 50 Mb/s of UDP from a station gets ~30 Mb/s: one frame at a time, 389 µs each; the rest overflows the queue.
    @Test func udpThroughTheAirGetsAbout30MbPerSecond() throws {
        let (sim, _, srv, tab, _) = try wlan()
        try srv.configureSink(true)
        let flow = try UdpFlow(node: tab, target: "10.0.0.100", bitsPerSecond: 50e6, seconds: 2)
        var t = sim.now
        for _ in 0..<20 {
            t += SAMPLE_NS
            sim.sched.runUntil(t)
            flow.sample(at: t)
        }
        let rates = flow.result.samples.map(\.bitsPerSecond)
        #expect(rates.count >= 18) // a finished flow adds at most its last point
        for r in rates[2...17] { #expect(abs(r - WIFI_GOODPUT) / WIFI_GOODPUT < 0.01) }
        #expect(drops(sim, .queueFull) > 0)
    }

    /// Spec M11 §6: the access point runs no spanning tree and relays no BPDU; a tagged frame from the cable is dropped; an untagged
    /// broadcast goes on the air.
    @Test func theAccessPointNeitherRunsNorRelaysSpanningTreeAndDropsTaggedFrames() throws {
        let (sim, ap, _) = try cell()
        let sw = Switch(sim: sim, id: "SW1")
        _ = try Link(sim: sim, try sw.iface("Gi0/1"), try ap.iface("Gi0"))
        sim.run(35 * S)
        let bpdu = { (e: SimEvent) in if case .bpdu? = e.frame?.payload { true } else { false } }
        #expect(sim.log.all.contains { $0.kind == .rx && $0.node == "AP1" && bpdu($0) })
        #expect(!sim.log.all.contains { $0.kind == .tx && $0.node == "AP1" && bpdu($0) })
        let ap2 = AccessPoint(sim: sim, id: "AP2")
        let probe = Probe(sim: sim, id: "P")
        _ = try Link(sim: sim, try probe.iface("eth0"), try ap2.iface("Gi0"))
        try probe.sendRaw(vlan: 10)
        try probe.sendRaw()
        sim.run(MS)
        #expect(drops(sim, .unknownVlan) == 1)
        #expect(sim.log.all.filter { $0.kind == .tx && $0.node == "AP2" && $0.iface == "Dot11Radio0" }.count == 1)
    }

    /// Spec M11 §5: DAD and the DHCP client start when the association does (DISCOVER and NS wait for the end of the Association
    /// Response's ACK, at 60.952 ms); the lease goes when the association ends and comes back with the next one.
    @Test func dhcpAndDadStartAtAssociationAndDhcpStopsWhenItEnds() throws {
        let sim = Sim()
        let ap = AccessPoint(sim: sim, id: "AP1")
        let srv = Host(sim: sim, id: "SRV")
        _ = try Link(sim: sim, try srv.iface("eth0"), try ap.iface("Gi0"))
        try srv.setIp("eth0", "192.168.1.2/24")
        try srv.configureDhcpServer(DhcpConfig(start: "192.168.1.100", end: "192.168.1.199"))
        let tab = Host(sim: sim, id: "TAB1", wifi: true)
        try tab.setDhcp(true)
        try tab.v6.configure("wlan0", Ipv6Config())
        try tab.station!.configure(StationConfig(ssid: "pac-track"))
        sim.run(2 * S)
        let data = sim.log.all.filter { $0.kind == .tx && $0.node == "TAB1" && !isMgmt($0) }
        #expect(data.prefix(2).map { "\($0.time / US) \(eventView($0).proto)" } == ["60952 ndp", "61129 dhcp"])
        #expect(drops(sim, .notAssociated) == 0 && tab.nic.ipv4.map { formatIp($0.addr) } == "192.168.1.100")
        ap.powered = false
        ap.reset()
        #expect(tab.nic.ipv4 == nil && tab.dhcp?.state == .initial)
        sim.run(1 * S)
        ap.powered = true
        ap.powerOn()
        sim.run(5 * S) // the next scan starts at 7.06 s
        #expect(tab.station!.state == .associated && tab.nic.ipv4.map { formatIp($0.addr) } == "192.168.1.100")
    }

    /// Spec M11 §6: the duplicate-address check crosses the air, from a station to its access point's stations and cable.
    @Test func duplicateAddressesAreFoundAcrossTheAir() throws {
        let (sim, _, srv, tab, phone) = try wlan()
        defer { withExtendedLifetime(sim) {} } // nodes refer to their Sim unowned
        expectError("Duplicate address: 10.0.0.1 is already used by TAB1 wlan0 on this segment") { try phone.setIp("wlan0", "10.0.0.1/24") }
        expectError("Duplicate address: 10.0.0.1 is already used by TAB1 wlan0 on this segment") { try srv.setIp("eth0", "10.0.0.1/24") }
        expectError("Duplicate address: 10.0.0.100 is already used by SRV eth0 on this segment") { try tab.setIp("wlan0", "10.0.0.100/24") }
    }
}
