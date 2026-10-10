import Testing
@testable import PacEngine

/// RIP on every addressed interface of `r`, `passive` among them.
private func rip(_ r: IpNode, passive: [String] = []) throws {
    try r.configureRip(RipConfig(interfaces: r.interfaces.filter { $0.ipv4 != nil }.map(\.name), passive: passive))
}

/// H1 192.168.1.10 — (Gi0/0) R1 (Gi0/1 10.0.12.1/30) — (Gi0/1 10.0.12.2/30) R2 (Gi0/0) — H2 192.168.2.10; RIP on both routers
/// from t = 0, no static routes.
private func pair(passiveLans: Bool = false) throws -> (sim: Sim, h1: Host, h2: Host, r1: Router, r2: Router) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let r1 = Router(sim: sim, id: "R1", ports: 2)
    let r2 = Router(sim: sim, id: "R2", ports: 2)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try r2.iface("Gi0/1"))
    _ = try Link(sim: sim, try r2.iface("Gi0/0"), try h2.iface("eth0"))
    try r1.setIp("Gi0/0", "192.168.1.1/24")
    try r1.setIp("Gi0/1", "10.0.12.1/30")
    try r2.setIp("Gi0/0", "192.168.2.1/24")
    try r2.setIp("Gi0/1", "10.0.12.2/30")
    try h1.setIp("eth0", "192.168.1.10/24")
    try h1.setGateway("192.168.1.1")
    try h2.setIp("eth0", "192.168.2.10/24")
    try h2.setGateway("192.168.2.1")
    for r in [r1, r2] { try rip(r, passive: passiveLans ? ["Gi0/0"] : []) }
    return (sim, h1, h2, r1, r2)
}

/// The spec's lab (M8 §1): R1–R2 10.0.12.0/30 (Gi0/1–Gi0/1), R1–R3 10.0.13.0/30 (Gi0/2–Gi0/1), R2–R3 10.0.23.0/30 (Gi0/2–Gi0/2),
/// H1 on R1 Gi0/0 (192.168.1.0/24), H2 on R2 Gi0/0 (192.168.2.0/24); RIP everywhere from t = 0, the LANs passive.
private func triangle() throws -> (sim: Sim, h1: Host, h2: Host, r1: Router, r2: Router, r3: Router, l12: Link) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let r1 = Router(sim: sim, id: "R1", ports: 3)
    let r2 = Router(sim: sim, id: "R2", ports: 3)
    let r3 = Router(sim: sim, id: "R3", ports: 3)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try h2.iface("eth0"), try r2.iface("Gi0/0"))
    let l12 = try Link(sim: sim, try r1.iface("Gi0/1"), try r2.iface("Gi0/1"))
    _ = try Link(sim: sim, try r1.iface("Gi0/2"), try r3.iface("Gi0/1"))
    _ = try Link(sim: sim, try r2.iface("Gi0/2"), try r3.iface("Gi0/2"))
    for (r, i, cidr) in [(r1, "Gi0/0", "192.168.1.1/24"), (r1, "Gi0/1", "10.0.12.1/30"), (r1, "Gi0/2", "10.0.13.1/30"),
                         (r2, "Gi0/0", "192.168.2.1/24"), (r2, "Gi0/1", "10.0.12.2/30"), (r2, "Gi0/2", "10.0.23.1/30"),
                         (r3, "Gi0/1", "10.0.13.2/30"), (r3, "Gi0/2", "10.0.23.2/30")] {
        try r.setIp(i, cidr)
    }
    try h1.setIp("eth0", "192.168.1.10/24")
    try h1.setGateway("192.168.1.1")
    try h2.setIp("eth0", "192.168.2.10/24")
    try h2.setGateway("192.168.2.1")
    try rip(r1, passive: ["Gi0/0"])
    try rip(r2, passive: ["Gi0/0"])
    try rip(r3)
    return (sim, h1, h2, r1, r2, r3, l12)
}

/// A RIP response as a router without RIP (a hand-made neighbour) would send it out of `ifName`.
private func inject(_ n: IpNode, _ ifName: String, _ entries: [RipEntry], srcPort: UInt16 = PORT_RIP) throws {
    let i = try n.iface(ifName)
    n.multicast(on: i, src: i.ipv4!.addr, group: RIP_GROUP, mac: RIP_MAC,
                .udp(makeUdp(srcPort: srcPort, dstPort: PORT_RIP, payload: .rip(RipMessage(command: RIP_RESPONSE, entries: entries)))))
}

/// The routing table's row for `dest`: "R <metric> via <next hop> <iface>", "S via <next hop>", "C <iface>", or nil.
private func route(_ r: IpNode, _ dest: String) throws -> String? {
    let c = try parseCidr(dest)
    return r.routes.view().first { $0.network == c.addr && $0.prefix == c.prefix }.map { v in
        if let m = v.metric { return "R \(m) via \(formatIp(v.nextHop!)) \(v.iface)" }
        return v.isStatic ? "S via \(formatIp(v.nextHop!))" : "C \(v.iface)"
    }
}

private struct RipTx: Equatable {
    let time: Int
    let iface: String
    let dst: String
    let command: UInt8
    /// "192.168.1.0/24 1"
    let entries: [String]
}

/// Every RIP message `node` put on a cable, in order.
private func ripTx(_ sim: Sim, _ node: String) -> [RipTx] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node, case .ipv4(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .rip(let m) = u.payload else {
            return nil
        }
        return RipTx(time: e.time, iface: e.iface ?? "", dst: formatIp(p.dst), command: m.command,
                     entries: m.entries.map { "\(formatIp($0.network))/\($0.prefix) \($0.metric)" })
    }
}

/// One echo request from `h` to `dst`; the TTL of the reply if it came back within a second.
private func pingTtl(_ sim: Sim, _ h: Host, _ dst: String) throws -> UInt8? {
    let seen = icmpSeen(h)
    h.sendPacket(try parseIp(dst), echoRequest())
    sim.run(1 * S)
    return seen.seen.first { $0.type == ICMP_ECHO_REPLY }?.ttl
}

@Suite struct RipTests {
    @Test func ripLeavesAsMulticastUdp520WithTtl1AndAskForTheWholeTableFirst() throws {
        let (sim, _, _, _, _) = try pair()
        sim.run(1 * MS)
        let first = try #require(sim.log.all.first { $0.kind == .tx && $0.node == "R1" && $0.iface == "Gi0/1" })
        #expect(first.frame?.dst == RIP_MAC)
        guard case .ipv4(let p)? = first.frame?.payload, case .udp(let u) = p.payload, case .rip(let m) = u.payload else {
            Issue.record("not a RIP message")
            return
        }
        #expect(formatIp(p.src) == "10.0.12.1" && p.dst == RIP_GROUP && p.ttl == 1 && u.srcPort == PORT_RIP && u.dstPort == PORT_RIP)
        #expect(m == RipMessage(command: RIP_REQUEST, entries: [RipEntry(afi: 0, network: 0, prefix: 0, metric: RIP_INFINITY)]))
    }

    @Test func anUpdateOfMoreThan25RoutesIsSplit() throws {
        let sim = Sim()
        let r1 = Router(sim: sim, id: "R1", ports: 2)
        let r2 = Router(sim: sim, id: "R2", ports: 2)
        _ = try Link(sim: sim, try Probe(sim: sim, id: "P").iface("eth0"), try r1.iface("Gi0/0"))
        _ = try Link(sim: sim, try r1.iface("Gi0/1"), try r2.iface("Gi0/1"))
        for v in 10..<40 {
            try r1.addSubinterface("Gi0/0.\(v)")
            try r1.setIp("Gi0/0.\(v)", "10.1.\(v).1/24")
        }
        try r1.setIp("Gi0/1", "10.0.12.1/30")
        try r2.setIp("Gi0/1", "10.0.12.2/30")
        try rip(r1)
        sim.run(1 * MS)
        let updates = ripTx(sim, "R1").filter { $0.iface == "Gi0/1" && $0.command == RIP_RESPONSE }
        #expect(updates.map(\.entries.count) == [25, 5])
        #expect(updates.first?.entries.first == "10.1.10.0/24 1" && updates.last?.entries.last == "10.1.39.0/24 1")
    }

    @Test func neighboursLearnEachOthersNetworksAtOnceAndThePingCrosses() throws {
        let (sim, h1, _, r1, r2) = try pair()
        sim.run(1 * MS)
        #expect(try route(r1, "192.168.2.0/24") == "R 1 via 10.0.12.2 Gi0/1")
        #expect(try route(r2, "192.168.1.0/24") == "R 1 via 10.0.12.1 Gi0/1")
        // R2 answers R1's request straight to it, split horizon applied.
        #expect(ripTx(sim, "R2").contains { $0.dst == "10.0.12.1" && $0.command == RIP_RESPONSE && $0.entries == ["192.168.2.0/24 1"] })
        sim.run(1 * S)
        // At 1 s the triggered update with what R1 learned goes to H1's LAN only: split horizon keeps it off Gi0/1.
        #expect(ripTx(sim, "R1").filter { $0.time == 1 * S } == [RipTx(time: 1 * S, iface: "Gi0/0", dst: "224.0.0.9", command: RIP_RESPONSE,
                                                                         entries: ["192.168.2.0/24 2"])])
        // H1's NIC is not in the RIP group: it took every update in silence.
        #expect(!sim.log.all.contains { $0.node == "H1" && $0.kind == .tx })
        #expect(try pingTtl(sim, h1, "192.168.2.10") == 62)
    }

    @Test func updatesLeaveEvery30SecondsWithSplitHorizonAndNothingLeavesAPassiveInterface() throws {
        let (sim, _, _, _, _) = try pair(passiveLans: true)
        sim.run(95 * S)
        let multicasts = ripTx(sim, "R1").filter { $0.dst == "224.0.0.9" }
        #expect(multicasts.allSatisfy { $0.iface == "Gi0/1" })
        let responses = multicasts.filter { $0.command == RIP_RESPONSE }
        #expect(responses.map { $0.time / MS } == [0, 30_000, 60_000, 90_000])
        #expect(responses.allSatisfy { $0.entries == ["192.168.1.0/24 1"] })
    }

    @Test func fifteenHopsIsReachableSixteenIsNotAndOddSendersAreIgnored() throws {
        let sim = Sim()
        let h1 = Host(sim: sim, id: "H1")
        let r1 = Router(sim: sim, id: "R1", ports: 2)
        let n = Router(sim: sim, id: "N", ports: 1)
        _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
        _ = try Link(sim: sim, try r1.iface("Gi0/1"), try n.iface("Gi0/0"))
        try r1.setIp("Gi0/0", "192.168.1.1/24")
        try r1.setIp("Gi0/1", "10.0.12.1/30")
        try n.setIp("Gi0/0", "10.0.12.2/30")
        try r1.routes.addStatic("172.18.0.0/16", "10.0.12.2")
        try rip(r1)
        try inject(n, "Gi0/0", [RipEntry(network: 0xAC10_0000, prefix: 16, metric: 15), RipEntry(network: 0xAC11_0000, prefix: 16, metric: 16),
                                RipEntry(network: 0xAC12_0000, prefix: 16, metric: 3), RipEntry(network: 0xC0A8_0100, prefix: 24, metric: 1)])
        try inject(n, "Gi0/0", [RipEntry(network: 0xAC13_0000, prefix: 16, metric: 1)], srcPort: 5000)
        sim.run(31 * S)
        #expect(try route(r1, "172.16.0.0/16") == "R 15 via 10.0.12.2 Gi0/1")
        #expect(try route(r1, "172.17.0.0/16") == nil)
        #expect(try route(r1, "172.18.0.0/16") == "S via 10.0.12.2") // the static route hides the RIP one
        #expect(try route(r1, "192.168.1.0/24") == "C Gi0/0") // a network of its own is never learned
        #expect(try route(r1, "172.19.0.0/16") == nil) // a response must come from port 520
        // Out of Gi0/0 at 30 s: 15 + 1 hops is unreachable; the hidden route is not advertised.
        #expect(ripTx(sim, "R1").first { $0.time == 30 * S && $0.iface == "Gi0/0" }?.entries == ["10.0.12.0/30 1", "172.16.0.0/16 16"])
    }

    @Test func aSilentNeighboursRouteTimesOutAfter180SecondsAndIsFlushed120SecondsLater() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(10 * S)
        try r2.configureRip(nil)
        sim.run(170 * S) // t = 180 s: R2's last update reached R1 a few µs after 0
        #expect(try route(r1, "192.168.2.0/24") == "R 1 via 10.0.12.2 Gi0/1")
        sim.run(1 * MS)
        #expect(try route(r1, "192.168.2.0/24") == nil)
        #expect(ripTx(sim, "R1").last { $0.iface == "Gi0/0" }?.entries == ["192.168.2.0/24 16"]) // triggered, poisoned
        sim.run(119 * S) // t ≈ 299 s: still advertised as unreachable
        #expect(r1.rip?.routes.contains { formatIp($0.network) == "192.168.2.0" && $0.metric == RIP_INFINITY } == true)
        #expect(ripTx(sim, "R1").first { $0.time == 270 * S && $0.iface == "Gi0/0" }?.entries.contains("192.168.2.0/24 16") == true)
        sim.run(1 * S) // t ≈ 300 s: garbage collected
        #expect(r1.rip?.routes.contains { formatIp($0.network) == "192.168.2.0" } == false)
        sim.run(30 * S)
        #expect(ripTx(sim, "R1").first { $0.time == 330 * S && $0.iface == "Gi0/0" }?.entries == ["10.0.12.0/30 1"])
    }

    @Test func aCableFaultPoisonsAtOnceAndTheTriangleFailsOverAtTheNextPeriodicUpdate() throws {
        let (sim, h1, _, r1, r2, r3, l12) = try triangle()
        sim.run(2 * S)
        #expect(try pingTtl(sim, h1, "192.168.2.10") == 62) // t = 3 s
        sim.run(37 * S) // t = 40 s
        l12.up = false
        #expect(try route(r1, "192.168.2.0/24") == nil)
        #expect(try route(r2, "192.168.1.0/24") == nil)
        sim.run(1 * MS)
        #expect(ripTx(sim, "R1").first { $0.time == 40 * S && $0.iface == "Gi0/2" }?.entries.contains("192.168.2.0/24 16") == true)
        #expect(try route(r3, "192.168.2.0/24") == "R 1 via 10.0.23.1 Gi0/2")
        sim.run(20 * S - 2 * MS) // t ≈ 59.999 s: R3 has not spoken since 30 s
        #expect(try route(r1, "192.168.2.0/24") == nil)
        sim.run(2 * MS) // R3's periodic update at 60 s
        #expect(try route(r1, "192.168.2.0/24") == "R 2 via 10.0.13.2 Gi0/2")
        #expect(try pingTtl(sim, h1, "192.168.2.10") == 61)
    }

    @Test func aPassiveInterfaceStillListensAndANonParticipatingOneIsNeitherAdvertisedNorHeard() throws {
        let sim = Sim()
        let r1 = Router(sim: sim, id: "R1", ports: 2)
        let r2 = Router(sim: sim, id: "R2", ports: 2)
        let n = Router(sim: sim, id: "N", ports: 1)
        _ = try Link(sim: sim, try n.iface("Gi0/0"), try r1.iface("Gi0/0"))
        _ = try Link(sim: sim, try r1.iface("Gi0/1"), try r2.iface("Gi0/1"))
        try n.setIp("Gi0/0", "192.168.1.2/24")
        try r1.setIp("Gi0/0", "192.168.1.1/24")
        try r1.setIp("Gi0/1", "10.0.12.1/30")
        try r2.setIp("Gi0/1", "10.0.12.2/30")
        try rip(r2)
        try r1.configureRip(RipConfig(interfaces: ["Gi0/1"]))
        try inject(n, "Gi0/0", [RipEntry(network: 0xAC10_0000, prefix: 16, metric: 1)])
        sim.run(1 * S)
        #expect(try route(r1, "172.16.0.0/16") == nil) // heard on Gi0/0, which does not take part
        #expect(try route(r2, "192.168.1.0/24") == nil) // not advertised
        try r1.configureRip(RipConfig(interfaces: ["Gi0/0", "Gi0/1"], passive: ["Gi0/0"]))
        try inject(n, "Gi0/0", [RipEntry(network: 0xAC10_0000, prefix: 16, metric: 1)])
        sim.run(2 * S) // the second triggered update waits until 2 s
        #expect(try route(r1, "172.16.0.0/16") == "R 1 via 192.168.1.2 Gi0/0")
        #expect(try route(r2, "192.168.1.0/24") == "R 1 via 10.0.12.1 Gi0/1")
        #expect(try route(r2, "172.16.0.0/16") == "R 2 via 10.0.12.1 Gi0/1")
        #expect(!ripTx(sim, "R1").contains { $0.iface == "Gi0/0" })
    }

    @Test func aRouterPoweredOffIsForgottenAtOnceAndOnPowerOnAsksItsNeighbours() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(5 * S)
        r1.powered = false
        r1.reset()
        #expect(r1.routes.view().allSatisfy { $0.metric == nil })
        #expect(try route(r2, "192.168.1.0/24") == nil) // R2 saw its line go down
        sim.run(45 * S) // t = 50 s
        r1.powered = true
        r1.powerOn()
        sim.run(1 * MS)
        #expect(ripTx(sim, "R1").first { $0.time == 50 * S && $0.iface == "Gi0/1" }?.command == RIP_REQUEST)
        #expect(try route(r1, "192.168.2.0/24") == "R 1 via 10.0.12.2 Gi0/1")
        #expect(try route(r2, "192.168.1.0/24") == "R 1 via 10.0.12.1 Gi0/1")
    }

    @Test func subinterfacesTakePartWithTaggedUpdates() throws {
        let sim = Sim()
        let r1 = Router(sim: sim, id: "R1", ports: 2)
        let r2 = Router(sim: sim, id: "R2", ports: 2)
        _ = try Link(sim: sim, try r1.iface("Gi0/0"), try r2.iface("Gi0/0"))
        _ = try Link(sim: sim, try r1.iface("Gi0/1"), try Probe(sim: sim, id: "P1").iface("eth0"))
        _ = try Link(sim: sim, try r2.iface("Gi0/1"), try Probe(sim: sim, id: "P2").iface("eth0"))
        for (r, n) in [(r1, 1), (r2, 2)] {
            try r.addSubinterface("Gi0/0.10")
            try r.setIp("Gi0/0.10", "10.0.10.\(n)/30")
            try r.setIp("Gi0/1", "192.168.\(n).1/24")
        }
        try rip(r1)
        try rip(r2)
        sim.run(1 * MS)
        #expect(try route(r1, "192.168.2.0/24") == "R 1 via 10.0.10.2 Gi0/0.10")
        #expect(sim.log.all.first { $0.kind == .tx && $0.node == "R1" && $0.iface == "Gi0/0" }?.frame?.vlan == 10)
    }

    @Test func aFirewallThatDeniesByDefaultDropsRipUntilUdp520IsAllowed() throws {
        let (sim, _, _, r1, _) = try pair()
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(defaultAction: .deny))
        sim.run(5 * S)
        #expect(try route(r1, "192.168.2.0/24") == nil)
        #expect(sim.log.all.contains { $0.kind == .drop && $0.node == "R1" && $0.reason == .firewallDefault && $0.packet?.dst == RIP_GROUP })
        let allow = FirewallRule(iface: "Gi0/1", direction: .inbound, action: .allow, proto: .udp, src: "any", dst: "any", port: 520)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [allow], defaultAction: .deny))
        sim.run(25 * S - MS)
        #expect(try route(r1, "192.168.2.0/24") == nil)
        sim.run(2 * MS) // R2's periodic update at 30 s
        #expect(try route(r1, "192.168.2.0/24") == "R 1 via 10.0.12.2 Gi0/1")
    }

    @Test func refusesRipSettingsThatCannotWork() throws {
        let (sim, _, _, r1, _) = try pair()
        defer { withExtendedLifetime(sim) {} } // nodes refer to their Sim unowned
        expectError("R1 has no interface Gi9/9") { try r1.configureRip(RipConfig(interfaces: ["Gi9/9"])) }
        expectError("Gi0/0 is passive but does not take part in RIP") { try r1.configureRip(RipConfig(interfaces: ["Gi0/1"], passive: ["Gi0/0"])) }
        #expect(r1.rip?.config == RipConfig(interfaces: ["Gi0/0", "Gi0/1"]))
        try r1.addSubinterface("Gi0/0.10")
        try r1.configureRip(RipConfig(interfaces: ["Gi0/0", "Gi0/0.10"]))
        expectError("Gi0/0.10 takes part in RIP") { try r1.removeSubinterface("Gi0/0.10") }
    }

    @Test func routesLearnedThroughAnInterfaceGoWhenItsAddressChangesOrItLeavesRip() throws {
        let (sim, _, _, r1, _) = try pair()
        sim.run(1 * MS)
        try r1.setIp("Gi0/1", "10.0.99.1/30")
        r1.rip?.refresh() // as Runtime does after .setIp
        #expect(try route(r1, "192.168.2.0/24") == nil) // 10.0.12.2 is no longer on a connected network
        let (sim2, _, _, r3, _) = try pair()
        sim2.run(1 * MS)
        try r3.configureRip(RipConfig(interfaces: ["Gi0/0"]))
        #expect(try route(r3, "192.168.2.0/24") == nil) // Gi0/1 no longer takes part
    }

    @Test func aPassiveInterfaceMadeActiveAsksAndAnnouncesAtOnce() throws {
        let (sim, _, _, r1, _) = try pair(passiveLans: true)
        sim.run(5 * S)
        try r1.configureRip(RipConfig(interfaces: ["Gi0/0", "Gi0/1"]))
        sim.run(1 * MS)
        #expect(ripTx(sim, "R1").filter { $0.iface == "Gi0/0" }.map { "\($0.time / MS) \($0.command) \($0.entries)" }
                == ["5000 1 [\"0.0.0.0/0 16\"]", "5000 2 [\"10.0.12.0/30 1\", \"192.168.2.0/24 2\"]"])
    }

    @Test func aRouterSavedPoweredOffSaysNothingWhenTheFileOpens() throws {
        let rip = RipConfig(interfaces: ["Gi0/0"])
        let t = Topology(nodes: [
            TopologyNode(id: "r1", kind: .router, name: "R1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "Gi0/0", cidr: "10.0.12.1/30")],
                         routes: [], rip: rip),
            TopologyNode(id: "r2", kind: .router, name: "R2", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "Gi0/0", cidr: "10.0.12.2/30")],
                         routes: [], powered: false, rip: rip),
        ], links: [LinkView(id: "l1", a: IfaceRef(node: "r1", iface: "Gi0/0"), b: IfaceRef(node: "r2", iface: "Gi0/0"))])
        let rt = Runtime()
        try rt.handle(.load(t))
        rt.advance(wallMs: 100)
        #expect(!rt.events(from: 0).contains { $0.node == "r2" && $0.kind == .tx })
    }

    @Test func theRuntimeRunsRipOnRoutersOnlyAndFollowsAddressChanges() throws {
        let rt = Runtime()
        let devices: [(String, DeviceKind, String)] = [("r1", .router, "R1"), ("r2", .router, "R2"), ("p", .pc, "PC1"), ("c", .cloud, "ISP")]
        for (id, kind, name) in devices {
            try rt.handle(.addNode(id: id, kind: kind, name: name))
        }
        expectError("PC1 cannot run RIP") { try rt.handle(.setRip(node: "p", config: RipConfig())) }
        expectError("ISP cannot run RIP") { try rt.handle(.setRip(node: "c", config: RipConfig())) }
        try rt.handle(.connect(id: "l1", a: IfaceRef(node: "r1", iface: "Gi0/0"), b: IfaceRef(node: "r2", iface: "Gi0/0")))
        try rt.handle(.connect(id: "l2", a: IfaceRef(node: "r2", iface: "Gi0/1"), b: IfaceRef(node: "p", iface: "eth0")))
        try rt.handle(.setIp(node: "r1", iface: "Gi0/0", cidr: "10.0.12.1/30"))
        try rt.handle(.setIp(node: "r2", iface: "Gi0/0", cidr: "10.0.12.2/30"))
        try rt.handle(.setIp(node: "r2", iface: "Gi0/1", cidr: "192.168.2.1/24"))
        try rt.handle(.setRip(node: "r1", config: RipConfig(interfaces: ["Gi0/0"])))
        try rt.handle(.setRip(node: "r2", config: RipConfig(interfaces: ["Gi0/0", "Gi0/1"], passive: ["Gi0/1"])))
        #expect(rt.snapshot().nodes[1].rip == RipConfig(interfaces: ["Gi0/0", "Gi0/1"], passive: ["Gi0/1"]))
        rt.advance(wallMs: 100)
        #expect(rt.snapshot().nodes[0].routes.last == RouteRow(dest: "192.168.2.0/24", nextHop: "10.0.12.2", iface: "Gi0/0", isStatic: false, metric: 1))
        try rt.handle(.setIp(node: "r2", iface: "Gi0/1", cidr: "192.168.3.1/24"))
        for _ in 0..<12 { rt.advance(wallMs: 100) } // past the 1 s between triggered updates
        #expect(rt.snapshot().nodes[0].routes.filter { $0.metric != nil }.map(\.dest) == ["192.168.3.0/24"])
        try rt.handle(.setRip(node: "r2", config: nil))
        #expect(rt.snapshot().nodes[1].rip == nil)
    }
}
