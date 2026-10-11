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
            "60213 tx AP1 Authentication, Open System, transazione 2, stato 0",
            "60382 rx TAB1 Authentication, Open System, transazione 2, stato 0",
            "60426 tx TAB1 Association Request, SSID=pac-track",
            "60619 rx AP1 Association Request, SSID=pac-track",
            "60663 tx AP1 Association Response, stato 0, AID=1",
            "60844 rx TAB1 Association Response, stato 0, AID=1",
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
        #expect(mgmtLog(sim).last == "5120844 rx TAB1 Association Response, stato 0, AID=1" && tab.station!.state == .associated)
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
}
