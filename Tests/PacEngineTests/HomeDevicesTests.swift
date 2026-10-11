import Testing
@testable import PacEngine

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct HomeDevicesTests {
    /// Spec M12 §2: a bridge-mode modem has a line port and an Ethernet port, no address, and repeats every frame to the other port.
    @Test func aModemRepeatsFramesBetweenItsTwoPorts() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "m", kind: .modem, name: "MODEM1"))
        try rt.handle(.addNode(id: "b", kind: .pc, name: "PC2"))
        try rt.handle(.connect(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "m", iface: "eth0")))
        try rt.handle(.connect(id: "l2", a: IfaceRef(node: "m", iface: "dsl0"), b: IfaceRef(node: "b", iface: "eth0")))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.2/24"))
        #expect(rt.snapshot().nodes[1].ifaces.map(\.name) == ["dsl0", "eth0"])
        expectError("MODEM1 has no IP stack") { try rt.handle(.setIp(node: "m", iface: "eth0", cidr: "10.0.0.3/24")) }
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 5_000)
        #expect(rt.snapshot().apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
    }

    /// Spec M12 §2: dsl0 sends at the VDSL2 upstream rate (20 Mb/s) and receives at the downstream one (100 Mb/s); a slower cable wins.
    @Test func aModemLineSendsAt20AndReceivesAt100Mbps() throws {
        let sim = Sim()
        let modem = Modem(sim: sim, id: "M")
        let a = Probe(sim: sim, id: "A")
        let b = Probe(sim: sim, id: "B")
        _ = try Link(sim: sim, try a.iface("eth0"), try modem.iface("eth0"))
        let line = try Link(sim: sim, try modem.iface("dsl0"), try b.iface("eth0"))
        // 84 B on the wire: 672 ns at 1 Gb/s, 6720 ns at 100 Mb/s, 33600 ns at 20 Mb/s; 500 ns of copper per cable.
        try a.sendRaw()
        try b.sendRaw()
        sim.run(MS)
        #expect(b.got.map(\.time) == [1172 + 33_600 + 500])
        #expect(a.got.map(\.time) == [6720 + 500 + 1172])
        try line.update(LinkOptions(bandwidthBps: 10e6))
        let start = sim.now
        try a.sendRaw()
        try b.sendRaw()
        sim.run(MS)
        #expect(b.got.last.map { $0.time - start } == 1172 + 67_200 + 500)
        #expect(a.got.last.map { $0.time - start } == 67_200 + 500 + 1172)
    }

    /// Spec M12 §3–§5: the NAS runs the sink, the console swaps its card like a laptop, the IoT devices have Wi-Fi only.
    @Test func nasConsoleAndIotAreHosts() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "n", kind: .nas, name: "NAS1"))
        try rt.handle(.addNode(id: "c", kind: .console, name: "CONSOLE1"))
        try rt.handle(.addNode(id: "l", kind: .smartBulb, name: "LAMP1"))
        try rt.handle(.addNode(id: "t", kind: .thermostat, name: "THERM1"))
        try rt.handle(.addNode(id: "s", kind: .smartSpeaker, name: "SPK1"))
        #expect(rt.snapshot().nodes.map { $0.ifaces.map(\.name) } == [["eth0"], ["eth0"], ["wlan0"], ["wlan0"], ["wlan0"]])
        try rt.handle(.setSink(node: "n", on: true))
        #expect(rt.snapshot().nodes[0].sink)
        expectError("CONSOLE1 cannot run a traffic sink") { try rt.handle(.setSink(node: "c", on: true)) }
        expectError("LAMP1 cannot run a traffic sink") { try rt.handle(.setSink(node: "l", on: true)) }
        expectError("NAS1 cannot run a DHCP server") {
            try rt.handle(.setDhcpServer(node: "n", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199")))
        }
        expectError("NAS1 cannot use Wi-Fi") { try rt.handle(.setStation(node: "n", config: StationConfig(ssid: "casa"))) }
        try rt.handle(.setStation(node: "c", config: StationConfig(ssid: "casa")))
        #expect(rt.snapshot().nodes[1].ifaces.map(\.name) == ["wlan0"])
        try rt.handle(.setStation(node: "c", config: nil))
        #expect(rt.snapshot().nodes[1].ifaces.map(\.name) == ["eth0"])
        for id in ["l", "t", "s"] { try rt.handle(.setStation(node: id, config: StationConfig(ssid: "casa"))) }
        expectError("LAMP1 has only a Wi-Fi card") { try rt.handle(.setStation(node: "l", config: nil)) }
        expectError("SPK1 has only a Wi-Fi card") { try rt.handle(.setStation(node: "s", config: nil)) }
        #expect(rt.snapshot().nodes[2...].map { $0.station?.config.ssid } == ["casa", "casa", "casa"])
    }
}
