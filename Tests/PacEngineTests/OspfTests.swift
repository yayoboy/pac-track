import Testing
@testable import PacEngine

/// OSPF on every addressed interface of `r`, `passive` among them.
private func ospf(_ r: IpNode, passive: [String] = [], pointToPoint: Bool = false, priority: Int = 1, routerId: String? = nil) throws {
    try r.configureOspf(OspfConfig(routerId: routerId, interfaces: r.interfaces.filter { $0.ipv4 != nil }.map {
        OspfInterfaceConfig(name: $0.name, passive: passive.contains($0.name), pointToPoint: pointToPoint, priority: priority)
    }))
}

/// H1 192.168.1.10 — (Gi0/0) R1 (Gi0/1 10.0.12.1/30) — (Gi0/1 10.0.12.2/30) R2 (Gi0/0) — H2 192.168.2.10; OSPF on both routers from
/// t = 0, the LANs passive. Router IDs: R1 192.168.1.1, R2 192.168.2.1.
private func pair(pointToPoint: Bool = false) throws -> (sim: Sim, h1: Host, h2: Host, r1: Router, r2: Router) {
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
    for r in [r1, r2] { try ospf(r, passive: ["Gi0/0"], pointToPoint: pointToPoint) }
    return (sim, h1, h2, r1, r2)
}

/// Routers on one hub, 10.0.0.0/24: R<n> has 10.0.0.<n> on Gi0/0 (router ID 10.0.0.<n>); OSPF is not started here.
private func hub(_ count: Int) throws -> (sim: Sim, routers: [Router]) {
    let sim = Sim()
    let hub = Hub(sim: sim, id: "HUB1")
    var routers: [Router] = []
    for n in 1...count {
        let r = Router(sim: sim, id: "R\(n)", ports: 1)
        _ = try Link(sim: sim, try r.iface("Gi0/0"), hub.interfaces[n - 1])
        try r.setIp("Gi0/0", "10.0.0.\(n)/24")
        routers.append(r)
    }
    return (sim, routers)
}

/// The spec's lab (M8 §1) with OSPF: R1–R2 10.0.12.0/30 (Gi0/1–Gi0/1), R1–R3 10.0.13.0/30 (Gi0/2–Gi0/1), R2–R3 10.0.23.0/30
/// (Gi0/2–Gi0/2), H1 on R1 Gi0/0, H2 on R2 Gi0/0; OSPF everywhere from t = 0, the LANs passive. Router IDs: R1 192.168.1.1,
/// R2 192.168.2.1, R3 10.0.23.2.
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
    try ospf(r1, passive: ["Gi0/0"])
    try ospf(r2, passive: ["Gi0/0"])
    try ospf(r3)
    return (sim, h1, h2, r1, r2, r3, l12)
}

/// `r`'s database: "<type> <id> <adv> <seq>".
private func lsdb(_ r: Router) -> [String] {
    r.ospf?.lsdb.map { "\($0.lsa.header.type) \(formatIp($0.lsa.header.id)) \(formatIp($0.lsa.header.adv)) \(String(UInt32(bitPattern: $0.lsa.header.seq), radix: 16))" } ?? []
}

/// The routing table's row for `dest`: "O <cost> via <next hop> <iface>", "R …", "S …", "C <iface>", or nil.
private func route(_ r: IpNode, _ dest: String) throws -> String? {
    let c = try parseCidr(dest)
    return r.routes.view().first { $0.network == c.addr && $0.prefix == c.prefix }.map { v in
        if let m = v.metric { return "\(v.ospf ? "O" : "R") \(m) via \(formatIp(v.nextHop!)) \(v.iface)" }
        return v.isStatic ? "S via \(formatIp(v.nextHop!))" : "C \(v.iface)"
    }
}

/// One echo request from `h` to `dst`; the TTL of the reply if it came back within a second.
private func pingTtl(_ sim: Sim, _ h: Host, _ dst: String) throws -> UInt8? {
    let seen = icmpSeen(h)
    h.sendPacket(try parseIp(dst), echoRequest())
    sim.run(1 * S)
    return seen.seen.first { $0.type == ICMP_ECHO_REPLY }?.ttl
}

private struct OspfTx: Equatable {
    let time: Int
    let iface: String
    let dst: String
    let ttl: UInt8
    let packet: OspfPacket
}

/// Every OSPF packet `node` put on a cable, in order.
private func ospfTx(_ sim: Sim, _ node: String) -> [OspfTx] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node, case .ipv4(let p)? = e.frame?.payload, case .ospf(let o) = p.payload else { return nil }
        return OspfTx(time: e.time, iface: e.iface ?? "", dst: formatIp(p.dst), ttl: p.ttl, packet: o)
    }
}

/// `node`'s OSPF state events: "<iface> <note>".
private func ospfEvents(_ sim: Sim, _ node: String) -> [String] {
    sim.log.all.filter { $0.kind == .state && $0.node == node && $0.proto == .ospf }.map { "\($0.iface ?? "") \($0.note ?? "")" }
}

private func oi(_ r: Router, _ name: String) -> OspfInterface? {
    r.ospf?.interfaces.first { $0.iface.name == name }
}

@Suite struct OspfTests {
    @Test func hellosLeaveEvery10SecondsToAllSpfRoutersWithTtl1() throws {
        let (sim, _, _, r1, _) = try pair()
        sim.run(25 * S)
        let hellos = ospfTx(sim, "R1").filter { $0.packet.body.type == 1 }
        #expect(hellos.map { $0.time / S } == [0, 10, 20])
        #expect(hellos.allSatisfy { $0.iface == "Gi0/1" && $0.dst == "224.0.0.5" && $0.ttl == 1 && formatIp($0.packet.routerId) == "192.168.1.1" })
        guard case .hello(let first) = hellos[0].packet.body, case .hello(let second) = hellos[1].packet.body else { return }
        #expect(first.neighbors.isEmpty && second.neighbors.map(formatIp) == ["192.168.2.1"])
        #expect(first.prefix == 30 && first.priority == 1 && first.dr == 0)
        #expect(formatIp(r1.ospf!.routerId) == "192.168.1.1")
    }

    @Test func neighboursMeetAtTheFirstHellosAndGo2WayAtTheSecond() throws {
        let (sim, _, _, r1, _) = try pair()
        sim.run(1 * MS)
        #expect(oi(r1, "Gi0/1")?.neighbors.map { "\(formatIp($0.id)) \($0.state.label)" } == ["192.168.2.1 Init"])
        sim.run(10 * S)
        #expect(oi(r1, "Gi0/1")?.neighbors.first?.state == .twoWay)
        sim.run(29 * S) // t ≈ 39 s: still waiting for the wait timer
        #expect(oi(r1, "Gi0/1")?.state == .waiting)
        #expect(ospfEvents(sim, "R1") == ["Gi0/1 Down → Waiting", "Gi0/1 vicino 192.168.2.1: Down → Init", "Gi0/1 vicino 192.168.2.1: Init → 2-Way"])
    }

    @Test func theWaitTimerMakesTheHighestRouterIdDrAndTheOtherBdr() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(40 * S + MS)
        let (a, b) = (try #require(oi(r1, "Gi0/1")), try #require(oi(r2, "Gi0/1")))
        #expect(a.state == .backup && b.state == .dr)
        #expect(formatIp(a.dr) == "10.0.12.2" && formatIp(a.bdr) == "10.0.12.1" && formatIp(b.dr) == "10.0.12.2" && formatIp(b.bdr) == "10.0.12.1")
        #expect(a.neighbors.first!.state >= .exStart && b.neighbors.first!.state >= .exStart)
        #expect(ospfEvents(sim, "R2").filter { !$0.contains("vicino") } == ["Gi0/1 Down → Waiting", "Gi0/1 Waiting → DR"])
    }

    @Test func priorityZeroIsNeverElectedAndALateHighPriorityRouterDoesNotPreempt() throws {
        let (sim, rs) = try hub(3)
        try ospf(rs[0], priority: 0)
        try ospf(rs[1])
        sim.run(41 * S)
        #expect(oi(rs[0], "Gi0/0")?.state == .drOther && oi(rs[1], "Gi0/0")?.state == .dr)
        #expect(oi(rs[1], "Gi0/0")?.bdr == 0) // the only other router may not be BDR
        sim.run(19 * S) // t = 60 s
        try ospf(rs[2], priority: 255)
        sim.run(25 * S) // t = 85 s
        #expect(oi(rs[1], "Gi0/0")?.state == .dr) // no preemption
        #expect(oi(rs[2], "Gi0/0")?.state == .backup) // it takes the empty BDR slot
        #expect(oi(rs[0], "Gi0/0")?.state == .drOther)
        #expect(oi(rs[0], "Gi0/0").map { "\(formatIp($0.dr)) \(formatIp($0.bdr))" } == "10.0.0.2 10.0.0.3")
    }

    @Test func pointToPointSkipsTheElectionAndStartsTheExchangeAfterTheHellos() throws {
        let (sim, _, _, r1, _) = try pair(pointToPoint: true)
        sim.run(10 * S + MS)
        let a = try #require(oi(r1, "Gi0/1"))
        #expect(a.state == .pointToPoint && a.dr == 0 && a.bdr == 0)
        #expect(a.neighbors.first!.state >= .exStart)
        #expect(ospfEvents(sim, "R1").first == "Gi0/1 Down → Point-to-point")
    }

    @Test func aNeighbourThatFallsSilentIsDroppedAfterTheDeadInterval() throws {
        let (sim, rs) = try hub(2)
        try ospf(rs[0])
        try ospf(rs[1])
        sim.run(50 * S) // R2's last Hello leaves at 50 s
        rs[1].powered = false
        rs[1].reset()
        sim.run(40 * S) // t = 90 s
        #expect(oi(rs[0], "Gi0/0")?.neighbors.count == 1)
        sim.run(1 * MS)
        #expect(oi(rs[0], "Gi0/0")?.neighbors.isEmpty == true)
        #expect(ospfEvents(sim, "R1").contains { $0.hasPrefix("Gi0/0 vicino 10.0.0.2:") && $0.hasSuffix("→ Down") })
    }

    @Test func aCableFaultKillsTheAdjacencyAtOnce() throws {
        let (sim, _, _, r1, _) = try pair()
        sim.run(50 * S)
        try r1.iface("Gi0/1").link!.up = false
        #expect(r1.ospf?.interfaces.isEmpty == true)
        #expect(sim.log.all.contains { $0.time == 50 * S && $0.node == "R1" && $0.proto == .ospf && ($0.note ?? "").hasSuffix("→ Down") })
    }

    @Test func theRouterIdIsTheConfiguredOneOrTheHighestAddressAndChangesOnlyOnRestart() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(1 * MS)
        try ospf(r1, passive: ["Gi0/0"], routerId: "1.1.1.1")
        sim.run(1 * MS)
        #expect(formatIp(r1.ospf!.routerId) == "192.168.1.1") // already running: kept until restart
        try r1.configureOspf(nil)
        try ospf(r1, passive: ["Gi0/0"], routerId: "1.1.1.1")
        sim.run(1 * MS)
        #expect(formatIp(r1.ospf!.routerId) == "1.1.1.1")
        sim.run(10 * S)
        #expect(oi(r2, "Gi0/1")?.neighbors.map { formatIp($0.id) }.contains("1.1.1.1") == true)
    }

    @Test func hostsAndRoutersWithoutOspfIgnoreItsMulticasts() throws {
        let (sim, rs) = try hub(2)
        let h = Host(sim: sim, id: "H")
        let gi = try rs[0].iface("Gi0/0")
        _ = try Link(sim: sim, try h.iface("eth0"), try #require(gi.link).peer(gi).node.interfaces[5])
        try h.setIp("eth0", "10.0.0.9/24")
        try ospf(rs[0])
        sim.run(25 * S)
        #expect(!sim.log.all.contains { ($0.node == "H" || $0.node == "R2") && $0.kind == .tx })
    }

    @Test func refusesOspfSettingsThatCannotWork() throws {
        let (sim, _, _, r1, _) = try pair()
        defer { withExtendedLifetime(sim) {} } // nodes refer to their Sim unowned
        expectError("R1 has no interface Gi9/9") { try r1.configureOspf(OspfConfig(interfaces: [OspfInterfaceConfig(name: "Gi9/9")])) }
        expectError("OSPF priority must be between 0 and 255") {
            try r1.configureOspf(OspfConfig(interfaces: [OspfInterfaceConfig(name: "Gi0/1", priority: 256)]))
        }
        expectError("Invalid router ID: \"1.2.3\"") { try r1.configureOspf(OspfConfig(routerId: "1.2.3")) }
        let bare = Router(sim: sim, id: "R9", ports: 1)
        expectError("R9 needs an IPv4 address or a router ID for OSPF") { try bare.configureOspf(OspfConfig()) }
        try r1.addSubinterface("Gi0/0.10")
        try r1.configureOspf(OspfConfig(interfaces: [OspfInterfaceConfig(name: "Gi0/0.10")]))
        expectError("Gi0/0.10 takes part in OSPF") { try r1.removeSubinterface("Gi0/0.10") }
    }

    @Test func theAdjacencyReachesFullMillisecondsAfterTheElection() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(40 * S + 10 * MS)
        let steps = sim.log.all.filter { $0.node == "R1" && $0.proto == .ospf && ($0.note ?? "").hasPrefix("vicino") }
        #expect(steps.map { $0.note! } == ["Down → Init", "Init → 2-Way", "2-Way → ExStart", "ExStart → Exchange", "Exchange → Loading", "Loading → Full"]
            .map { "vicino 192.168.2.1: \($0)" })
        #expect(steps.last!.time > 40 * S)
        #expect(oi(r1, "Gi0/1")?.neighbors.first?.master == false && oi(r2, "Gi0/1")?.neighbors.first?.master == true) // R2: higher router ID
        let dbds = ospfTx(sim, "R2").compactMap { if case .dbd(let d) = $0.packet.body { "\(d.seq)\(d.initial ? " I" : "")\(d.master ? " MS" : "")" } else { nil } }
        #expect(dbds == ["40000 I MS", "40001 MS"])
    }

    @Test func bothRoutersEndWithTheSameDatabase() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(46 * S)
        #expect(lsdb(r1) == ["1 192.168.1.1 192.168.1.1 80000002", "1 192.168.2.1 192.168.2.1 80000002", "2 10.0.12.2 192.168.2.1 80000001"])
        #expect(lsdb(r2) == lsdb(r1))
        let entries = r1.ospf!.lsdb
        #expect(entries[1].lsa.body == .router([
            RouterLink(type: LINK_STUB, id: 0xC0A8_0200, data: 0xFFFF_FF00, metric: 1),
            RouterLink(type: LINK_TRANSIT, id: 0x0A00_0C02, data: 0x0A00_0C02, metric: 1),
        ]))
        #expect(entries[2].lsa.body == .network(prefix: 30, routers: [0xC0A8_0201, 0xC0A8_0101]))
        for e in entries { #expect(fletcher(Array(serialize(e.lsa).dropFirst(2)), at: 14) == e.lsa.header.checksum) }
    }

    @Test func aLostUpdateIsRetransmittedAfter5Seconds() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(46 * S)
        let l12 = try #require(try r1.iface("Gi0/1").link)
        try l12.update(LinkOptions(lossRate: 1))
        try #require(try r2.iface("Gi0/0").link).update(LinkOptions(bandwidthBps: 10e6)) // R2's LAN stub now costs 10
        sim.run(1 * S)
        try l12.update(LinkOptions())
        sim.run(4 * S - MS) // t ≈ 50.999 s
        #expect(lsdb(r1).contains("1 192.168.2.1 192.168.2.1 80000002"))
        sim.run(2 * MS)
        #expect(lsdb(r1).contains("1 192.168.2.1 192.168.2.1 80000003"))
        #expect(ospfTx(sim, "R2").contains { $0.time == 51 * S && $0.dst == "10.0.12.1" && $0.packet.body.type == 4 }) // a unicast LS Update
    }

    @Test func aRouterThatRestartsJumpsPastItsOldSequenceNumbers() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(50 * S)
        r2.powered = false
        r2.reset()
        sim.run(10 * S) // t = 60 s
        r2.powered = true
        r2.powerOn()
        sim.run(46 * S) // waits 40 s again, then exchanges
        #expect(lsdb(r1).contains("1 192.168.2.1 192.168.2.1 80000003"))
        #expect(lsdb(r2).contains("1 192.168.2.1 192.168.2.1 80000003"))
    }

    @Test func ownLsasAreRefreshedEvery1800Seconds() throws {
        let (sim, _, _, r1, r2) = try pair()
        sim.run(1839 * S)
        #expect(lsdb(r2).contains("1 192.168.1.1 192.168.1.1 80000002"))
        sim.run(2 * S) // R1's router-LSA was originated a few µs after 40 s
        #expect(lsdb(r1).contains("1 192.168.1.1 192.168.1.1 80000003"))
        #expect(lsdb(r2).contains("1 192.168.1.1 192.168.1.1 80000003"))
    }

    @Test func aDrThatLosesItsLastNeighbourFlushesItsNetworkLsa() throws {
        let (sim, _, _, r1, _, r3, l12) = try triangle()
        sim.run(50 * S)
        #expect(lsdb(r1).contains { $0.hasPrefix("2 10.0.12.2 192.168.2.1") })
        l12.up = false
        sim.run(10 * MS)
        #expect(!lsdb(r1).contains { $0.hasPrefix("2 10.0.12.2") } && !lsdb(r3).contains { $0.hasPrefix("2 10.0.12.2") })
    }

    @Test func spfInstallsRoutesFiveSecondsAfterTheFirstDatabaseChange() throws {
        let (sim, h1, _, r1, _) = try pair()
        sim.run(45 * S - 10 * MS)
        #expect(try route(r1, "192.168.2.0/24") == nil)
        sim.run(20 * MS)
        #expect(try route(r1, "192.168.2.0/24") == "O 2 via 10.0.12.2 Gi0/1")
        #expect(try route(r1, "10.0.12.0/30") == "C Gi0/1") // a network of its own stays connected
        #expect(try pingTtl(sim, h1, "192.168.2.10") == 62)
        let (p2p, _, _, q1, _) = try pair(pointToPoint: true)
        p2p.run(15 * S - 10 * MS)
        #expect(try route(q1, "192.168.2.0/24") == nil)
        p2p.run(20 * MS)
        #expect(try route(q1, "192.168.2.0/24") == "O 2 via 10.0.12.2 Gi0/1")
    }

    @Test func aSlowerCableCostsMoreAndTheTriangleRoutesAroundIt() throws {
        let (sim, _, _, r1, _, _, l12) = try triangle()
        sim.run(46 * S)
        #expect(try route(r1, "192.168.2.0/24") == "O 2 via 10.0.12.2 Gi0/1")
        try l12.update(LinkOptions(bandwidthBps: 10e6)) // cost 100 Mb/s ÷ 10 Mb/s = 10
        sim.run(5 * S + 10 * MS)
        #expect(try route(r1, "192.168.2.0/24") == "O 3 via 10.0.13.2 Gi0/2")
    }

    @Test func aCableFaultMovesTrafficToTheThirdRouterAtTheNextSpf() throws {
        let (sim, h1, _, r1, _, _, l12) = try triangle()
        sim.run(50 * S)
        l12.up = false
        sim.run(5 * S - 10 * MS) // t ≈ 54.99 s: the SPF has not run yet
        #expect(try route(r1, "192.168.2.0/24") == "O 2 via 10.0.12.2 Gi0/1")
        sim.run(20 * MS)
        #expect(try route(r1, "192.168.2.0/24") == "O 3 via 10.0.13.2 Gi0/2")
        #expect(try pingTtl(sim, h1, "192.168.2.10") == 61)
    }

    @Test func ospfBeatsRipAndStaticBeatsOspf() throws {
        let (sim, _, _, r1, r2) = try pair()
        for r in [r1, r2] { try r.configureRip(RipConfig(interfaces: ["Gi0/0", "Gi0/1"], passive: ["Gi0/0"])) }
        sim.run(2 * S)
        #expect(try route(r1, "192.168.2.0/24") == "R 1 via 10.0.12.2 Gi0/1")
        sim.run(44 * S)
        #expect(try route(r1, "192.168.2.0/24") == "O 2 via 10.0.12.2 Gi0/1") // 110 beats 120
        try r1.routes.addStatic("192.168.2.0/24", "10.0.12.2")
        #expect(try route(r1, "192.168.2.0/24") == "S via 10.0.12.2")
    }
}
