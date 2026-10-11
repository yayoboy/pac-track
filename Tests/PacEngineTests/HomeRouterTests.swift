import Testing
@testable import PacEngine

/// HR1 (LAN 192.168.0.1/24) with PC1 on LAN1 (.10), PC2 on LAN2 (.11) and TAB1 on the air (.12), associated; at 100 ms.
private func home() throws -> (sim: Sim, hr: HomeRouter, pc1: Host, pc2: Host, tab: Host) {
    let sim = Sim()
    let hr = HomeRouter(sim: sim, id: "HR1")
    try hr.setIp("LAN", "192.168.0.1/24")
    let pc1 = Host(sim: sim, id: "PC1")
    let pc2 = Host(sim: sim, id: "PC2")
    _ = try Link(sim: sim, try pc1.iface("eth0"), try hr.iface("LAN1"))
    _ = try Link(sim: sim, try pc2.iface("eth0"), try hr.iface("LAN2"))
    let tab = Host(sim: sim, id: "TAB1", wifi: true)
    try tab.station!.configure(StationConfig(ssid: "pac-track"))
    sim.run(100 * MS)
    try pc1.setIp("eth0", "192.168.0.10/24")
    try pc2.setIp("eth0", "192.168.0.11/24")
    try tab.setIp("wlan0", "192.168.0.12/24")
    return (sim, hr, pc1, pc2, tab)
}

/// Whether an echo request from `node` to `target` gets its reply within a second.
private func pings(_ sim: Sim, _ node: Host, _ target: String) throws -> Bool {
    let seen = icmpSeen(node)
    node.sendPacket(try parseIp(target), echoRequest())
    sim.run(1 * S)
    return seen.seen.contains { $0.from == target && $0.type == ICMP_ECHO_REPLY }
}

/// The interfaces a frame left HR1 by.
private func outOf(_ sim: Sim, _ frame: Int) -> [String] {
    sim.log.all.filter { $0.frame?.id == frame && $0.kind == .tx && $0.node == "HR1" }.compactMap(\.iface)
}

/// The last frame `node` sent.
private func lastSent(_ sim: Sim, _ node: String) -> Int {
    sim.log.all.last { $0.kind == .tx && $0.node == node }!.frame!.id
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct HomeRouterTests {
    /// Spec M11 §8: the Internet port, LAN1–LAN4, the radio WLAN and the bridge interface LAN that holds the address; LAN takes no
    /// cable and the bridge's ports take no address; TTL 64 like the Linux inside.
    @Test func aHomeRouterHasAnInternetPortFourLanPortsARadioAndTheLanBridge() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "hr", kind: .homeRouter, name: "HR1"))
        try rt.handle(.addNode(id: "p", kind: .pc, name: "PC1"))
        let hr = rt.snapshot().nodes[0]
        #expect(hr.ifaces.map(\.name) == ["Internet", "LAN1", "LAN2", "LAN3", "LAN4", "WLAN", "LAN"])
        #expect(hr.ifaces.map(\.wireless) == [false, false, false, false, false, true, false] && hr.ifaces[6].linked)
        #expect(hr.accessPoint == AccessPointView(config: ApConfig(), clients: []))
        expectError("Cannot cable a bridge interface") {
            try rt.handle(.connect(id: "l", a: IfaceRef(node: "p", iface: "eth0"), b: IfaceRef(node: "hr", iface: "LAN")))
        }
        for port in ["LAN1", "WLAN"] {
            expectError("\(port) is a port of the LAN bridge") { try rt.handle(.setIp(node: "hr", iface: port, cidr: "192.168.0.5/24")) }
            expectError("\(port) is a port of the LAN bridge") { try rt.handle(.setIpv6(node: "hr", iface: port, config: Ipv6Config())) }
        }
        expectError("HR1 uses DHCP only on Internet") { try rt.handle(.setIfaceMode(node: "hr", iface: "LAN", mode: .dhcp)) }
        expectError("HR1 cannot run RIP") { try rt.handle(.setRip(node: "hr", config: RipConfig())) }
        try rt.handle(.setIp(node: "hr", iface: "LAN", cidr: "192.168.0.1/24"))
        try rt.handle(.setDhcpServer(node: "hr", config: DhcpConfig(start: "192.168.0.100", end: "192.168.0.149", gateway: "192.168.0.1")))
        try rt.handle(.setNat(node: "hr", config: NatConfig(inside: ["LAN"], outside: "Internet")))
        try rt.handle(.setFirewall(node: "hr", config: FirewallConfig()))
        try rt.handle(.setIfaceMode(node: "hr", iface: "Internet", mode: .dhcp))
        try rt.handle(.setAccessPoint(node: "hr", config: ApConfig(ssid: "casa", channel: 11, passphrase: "segreta123")))
        let s = rt.snapshot().nodes[0]
        #expect(s.ifaces[0].mode == .dhcp && s.dhcpClient != nil && s.accessPoint?.config.ssid == "casa" && s.nat != nil)
        let sim = Sim()
        let probe = HomeRouter(sim: sim, id: "HR2")
        #expect(probe.defaultTtl == 64)
        withExtendedLifetime(sim) {}
    }

    /// Spec M11 §8: the LAN ports and the air are one broadcast domain around 192.168.0.1: pings cross it, the duplicate check sees
    /// across it.
    @Test func lanPortsAndTheAirAreOneSegment() throws {
        let (sim, hr, pc1, pc2, tab) = try home()
        #expect(try pings(sim, pc1, "192.168.0.11") && pings(sim, pc1, "192.168.0.12") && pings(sim, tab, "192.168.0.1"))
        #expect(try pings(sim, pc2, "192.168.0.1") && pings(sim, tab, "192.168.0.11"))
        #expect(hr.lan.segmentPeers().map(\.id).sorted() == ["PC1/eth0", "PC2/eth0", "TAB1/wlan0"])
        #expect(pc1.nic.segmentPeers().map(\.id).sorted() == ["HR1/LAN", "PC2/eth0", "TAB1/wlan0"])
        let pc3 = Host(sim: sim, id: "PC3")
        _ = try Link(sim: sim, try pc3.iface("eth0"), try hr.iface("LAN3"))
        expectError("Duplicate address") { try pc3.setIp("eth0", "192.168.0.12/24") }
    }

    /// Spec M11 §8: the bridge learns where each MAC is, floods only to cabled ports, never sends a frame back out of its port, and
    /// relays a station's broadcast once back on the air.
    @Test func theBridgeLearnsAndNeverEchoes() throws {
        let (sim, _, pc1, _, tab) = try home()
        #expect(try pings(sim, pc1, "192.168.0.11") && pings(sim, tab, "192.168.0.10"))
        pc1.sendPacket(try parseIp("192.168.0.11"), echoRequest())
        let request = lastSent(sim, "PC1")
        sim.run(1 * S)
        #expect(outOf(sim, request) == ["LAN2"])
        pc1.sendPacket(try parseIp("192.168.0.99"), echoRequest()) // an ARP broadcast for nobody
        sim.run(10 * MS)
        let broadcast = sim.log.all.last { $0.kind == .tx && $0.node == "PC1" }!.frame!.id
        #expect(outOf(sim, broadcast) == ["WLAN", "LAN2"])
        tab.sendPacket(try parseIp("192.168.0.98"), echoRequest())
        sim.run(10 * MS)
        let fromAir = sim.log.all.last { $0.kind == .tx && $0.node == "TAB1" }!.frame!.id
        // Back on the air after the medium's ACK of the station's frame: the cables first.
        #expect(outOf(sim, fromAir) == ["LAN1", "LAN2", "WLAN"])
        #expect(drops(sim, .noLink) == 0)
    }

    /// Spec M11 §8: the Internet port takes its address, default route and name server from the provider's DHCP; the LAN gets its
    /// addresses from HR1, with HR1 as name server forwarding to the provider's, and reaches the Internet through NAT.
    @Test func theInternetPortTakesItsAddressFromTheIspAndNatsTheLan() throws {
        let sim = Sim()
        let isp = Cloud(sim: sim, id: "ISP1")
        try isp.setIp("Gi0/0", "203.0.113.1/24")
        try isp.configureDhcpServer(DhcpConfig(start: "203.0.113.100", end: "203.0.113.199", gateway: "203.0.113.1", dns: "203.0.113.1"))
        try isp.configureDnsServer([DnsRecord(name: "www.example.com", ip: "198.51.100.10")])
        let hr = HomeRouter(sim: sim, id: "HR1")
        try hr.setIp("LAN", "192.168.0.1/24")
        try hr.configureDhcpServer(DhcpConfig(start: "192.168.0.100", end: "192.168.0.149", gateway: "192.168.0.1", dns: "192.168.0.1"))
        hr.nat = try Nat(node: hr, config: NatConfig(inside: ["LAN"], outside: "Internet"))
        try hr.setDhcp(true, on: hr.wan)
        _ = try Link(sim: sim, try isp.iface("Gi0/0"), try hr.iface("Internet"))
        sim.run(2 * S)
        #expect(hr.wan.ipv4.map { formatIp($0.addr) } == "203.0.113.100" && hr.learnedNameServer.map(formatIp) == "203.0.113.1")
        let pc = Host(sim: sim, id: "PC1")
        _ = try Link(sim: sim, try pc.iface("eth0"), try hr.iface("LAN1"))
        try pc.setDhcp(true)
        sim.run(2 * S)
        #expect(pc.nic.ipv4.map { formatIp($0.addr) } == "192.168.0.100" && pc.learnedNameServer.map(formatIp) == "192.168.0.1")
        #expect(try pings(sim, pc, "198.51.100.10") && hr.nat!.view().map { formatIp($0.global) } == ["203.0.113.100"])
        // Names: asked of HR1, which asks ISP1 (dnsmasq-like); an unknown name stays unknown.
        var answers: [Resolution] = []
        for name in ["www.example.com", "nessuno.example"] { pc.resolver.lookup(name, server: .v4(try parseIp("192.168.0.1")), useCache: false) { answers.append($0) } }
        sim.run(1 * S)
        #expect(answers == [.found([.v4(try parseIp("198.51.100.10"))]), .nxdomain])
        #expect(sim.log.all.contains { $0.kind == .tx && $0.node == "HR1" && $0.iface == "Internet" && eventView($0).info.contains("DNS") })
    }

    /// Spec M11 §8: no spanning tree: a switch's BPDUs stop at the bridge; tagged frames are dropped.
    @Test func noSpanningTreeNoBpdusAndTaggedFramesDropped() throws {
        let (sim, hr, _, _, _) = try home()
        let sw = Switch(sim: sim, id: "SW1")
        _ = try Link(sim: sim, try sw.iface("Gi0/1"), try hr.iface("LAN3"))
        let probe = Probe(sim: sim, id: "P")
        _ = try Link(sim: sim, try probe.iface("eth0"), try hr.iface("LAN4"))
        sim.run(3 * S)
        let bpdus = sim.log.all.filter { e in
            guard e.kind == .tx, e.node == "HR1", case .bpdu? = e.frame?.payload else { return false }
            return true
        }
        #expect(bpdus.isEmpty && sim.log.all.contains { $0.kind == .rx && $0.node == "HR1" && $0.iface == "LAN3" })
        try probe.sendRaw(vlan: 10)
        sim.run(10 * MS)
        #expect(drops(sim, .unknownVlan) == 1)
    }

    /// Spec M11 §5, §8: switched off, its stations lose the association at once.
    @Test func switchedOffItDropsItsStations() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "hr", kind: .homeRouter, name: "HR1"))
        try rt.handle(.addNode(id: "t", kind: .tablet, name: "TAB1"))
        try rt.handle(.setStation(node: "t", config: StationConfig(ssid: "pac-track")))
        runFor(rt, wallMs: 200)
        #expect(rt.snapshot().nodes[1].station?.ap == "hr" && rt.snapshot().nodes[0].accessPoint?.clients.count == 1)
        try rt.handle(.setPower(id: "hr", on: false))
        #expect(rt.snapshot().nodes[1].station?.state == .scanning && rt.snapshot().nodes[0].accessPoint?.clients == [])
    }
}
