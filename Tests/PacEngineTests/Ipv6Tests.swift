import Testing
@testable import PacEngine

/// A and B on one cable (no switch: no spanning tree delay).
private func cable() throws -> (sim: Sim, a: Host, b: Host) {
    let sim = Sim()
    let a = Host(sim: sim, id: "A")
    let b = Host(sim: sim, id: "B")
    _ = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"))
    return (sim, a, b)
}

/// A (2001:db8::1/64) and B (2001:db8::2/64) on one cable, past DAD (t = 2 s).
private func pair() throws -> (sim: Sim, a: Host, b: Host) {
    let (sim, a, b) = try cable()
    try a.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
    try b.v6.configure("eth0", Ipv6Config(address: "2001:db8::2/64"))
    sim.run(2 * S)
    return (sim, a, b)
}

/// "address mac STATE" per neighbour.
private func neighbors(_ n: IpNode) -> [String] {
    n.v6.neighbors.view().map { "\(formatIp6($0.addr)) \($0.mac ?? "-") \($0.state.rawValue)" }
}

/// H1 (SLAAC unless told otherwise) — R1 Gi0/0 (2001:db8:1::1/64, `ipv6 unicast-routing` unless told otherwise), configured at t = 0.
/// MACs: H1 eth0 …:01, R1 Gi0/0 …:02.
private func edge(slaac: Bool = true, routing: Bool = true) throws -> (sim: Sim, h1: Host, r1: Router) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let r1 = Router(sim: sim, id: "R1", ports: 2)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:1::1/64"))
    r1.v6.setRouting(routing)
    try h1.v6.configure("eth0", Ipv6Config(autoconfig: slaac))
    return (sim, h1, r1)
}

/// When a node sent NDP messages of one type.
private func ndp(_ sim: Sim, by node: String, _ type: UInt8) -> [Int] {
    sent(sim, by: node).filter { if case .ndp(let n) = $0.p.payload { n.type == type } else { false } }.map(\.time)
}

private let ELSEWHERE = UInt128(0x2001_0DB8_0009) << 80 | 1 // 2001:db8:9::1

/// H1 — R1 (Gi0/0 2001:db8:1::1/64 | Gi0/1 2001:db8:2::1/64, `ipv6 unicast-routing`) — H2, dual stack (IPv4 from `routedPair`),
/// both hosts on SLAAC, autoconfigured (t = 3 s). MACs: H1 …:01, H2 …:02, R1 Gi0/0 …:03, Gi0/1 …:04.
private func routed() throws -> (sim: Sim, h1: Host, h2: Host, r1: Router) {
    let (sim, h1, h2, r1) = try routedPair()
    try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:1::1/64"))
    try r1.v6.configure("Gi0/1", Ipv6Config(address: "2001:db8:2::1/64"))
    r1.v6.setRouting(true)
    for h in [h1, h2] { try h.v6.configure("eth0", Ipv6Config(autoconfig: true)) }
    sim.run(3 * S)
    return (sim, h1, h2, r1)
}

private let H2 = "2001:db8:2::ff:fe00:2"

/// "address state" for every IPv6 address of an interface, in its order.
private func states(_ n: IpNode, _ iface: String = "eth0") -> [String] {
    ((try? n.iface(iface))?.v6?.addrs ?? []).map { "\(formatIp6($0.addr)) \($0.state)" }
}

/// IPv6 packets a node transmitted, with their time and frame destination.
private func sent(_ sim: Sim, by node: String) -> [(time: Int, p: Ipv6Packet, dst: Mac)] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node, let f = e.frame, case .ipv6(let p) = f.payload else { return nil }
        return (e.time, p, f.dst)
    }
}

@Suite struct Ipv6Tests {
    @Test func everyNewAddressSendsOneDadNsAndBecomesUsableAfter1Second() throws {
        let (sim, a, _) = try cable()
        try a.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        sim.run(999 * MS)
        #expect(states(a) == ["fe80::ff:fe00:1 tentative", "2001:db8::1 tentative"])
        #expect(!a.v6.owns(try parseIp6("2001:db8::1")))
        let dad = sent(sim, by: "A")
        #expect(dad.map(\.time) == [0, 816]) // the second NS waits for the first to leave the cable (102 B on the wire at 1 Gb/s)
        // Both addresses end in 00:0001, so they share a solicited-node group.
        #expect(dad.allSatisfy { formatIp6($0.p.dst) == "ff02::1:ff00:1" && $0.dst == "33:33:ff:00:00:01" && $0.p.src == 0 && $0.p.hopLimit == 255 })
        #expect(dad.map(\.p.payload) == [.ndp(NdpMessage(body: .ns(target: linkLocal(try a.iface("eth0").mac), slla: nil))),
                                         .ndp(NdpMessage(body: .ns(target: try parseIp6("2001:db8::1"), slla: nil)))].map(sealedLike(dad[0].p)))
        sim.run(1 * MS)
        #expect(states(a) == ["fe80::ff:fe00:1 preferred", "2001:db8::1 preferred"])
        #expect(a.v6.owns(try parseIp6("2001:db8::1")))
        #expect(sent(sim, by: "B").isEmpty) // IPv6 off: B's NIC drops the group, and B sends nothing
    }

    @Test func aNeighbourAnsweringTheDadMakesTheAddressDuplicate() throws {
        let (sim, a, b) = try cable()
        try b.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        sim.run(2 * S)
        try a.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        sim.run(2 * S)
        #expect(states(a).last == "2001:db8::1 duplicate" && states(b).last == "2001:db8::1 preferred")
        let na = try #require(sent(sim, by: "B").last)
        #expect(formatIp6(na.p.dst) == "ff02::1" && na.dst == "33:33:00:00:00:01")
        let note = sim.log.all.first { $0.kind == .state }
        #expect(note?.node == "A" && note?.iface == "eth0" && note?.proto == .ndp && note?.note == "DAD: 2001:db8::1 duplicato")
        #expect(!a.v6.owns(try parseIp6("2001:db8::1")))
    }

    @Test func twoNodesRunningDadForTheSameAddressAtOnceBothGiveItUp() throws {
        let (sim, a, b) = try cable()
        try a.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        try b.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        sim.run(2 * S)
        #expect(states(a).last == "2001:db8::1 duplicate" && states(b).last == "2001:db8::1 duplicate")
    }

    @Test func dadWaitsForTheLineAndRunsAgainWhenItComesBack() throws {
        let sim = Sim()
        let a = Host(sim: sim, id: "A")
        let b = Host(sim: sim, id: "B")
        try a.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        sim.run(5 * S)
        #expect(states(a).last == "2001:db8::1 tentative" && sent(sim, by: "A").isEmpty)
        let link = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"))
        sim.run(999 * MS)
        #expect(ndp(sim, by: "A", ND_NS) == [5 * S, 5 * S + 816] && states(a).last == "2001:db8::1 tentative")
        sim.run(1 * MS)
        #expect(states(a).last == "2001:db8::1 preferred")
        link.up = false
        sim.run(2 * S)
        #expect(states(a).last == "2001:db8::1 preferred") // a line going down changes nothing
        link.up = true
        #expect(states(a).last == "2001:db8::1 tentative")
        sim.run(1 * S)
        #expect(ndp(sim, by: "A", ND_NS).suffix(2) == [8 * S, 8 * S + 816] && states(a).last == "2001:db8::1 preferred")
    }

    @Test func aPowerCycleRunsDadAgain() throws {
        let (sim, a, _) = try cable()
        try a.v6.configure("eth0", Ipv6Config(address: "2001:db8::1/64"))
        sim.run(2 * S)
        a.powered = false
        a.reset()
        #expect(states(a).last == "2001:db8::1 tentative")
        sim.run(1 * S)
        a.powered = true
        a.powerOn()
        sim.run(999 * MS)
        #expect(ndp(sim, by: "A", ND_NS).suffix(2) == [3 * S, 3 * S + 816] && states(a).last == "2001:db8::1 tentative")
        sim.run(1 * MS)
        #expect(states(a).last == "2001:db8::1 preferred")
    }

    @Test func aPingResolvesTheNeighbourWithNsAndNaFirst() throws {
        let (sim, a, b) = try pair()
        let ping = try Ping(node: a, target: "2001:db8::2", options: PingOptions(count: 1))
        sim.run(100 * MS)
        #expect(ping.result.lines == ["PING 2001:db8::2(2001:db8::2) 56 data bytes",
                                      "64 bytes from 2001:db8::2: icmp_seq=1 ttl=64 time=0.006 ms",
                                      "--- 2001:db8::2 ping statistics ---",
                                      "1 packets transmitted, 1 received, 0% packet loss"])
        let ns = try #require(sent(sim, by: "A").first { $0.time == 2 * S })
        #expect(formatIp6(ns.p.src) == "2001:db8::1" && formatIp6(ns.p.dst) == "ff02::1:ff00:2" && ns.dst == "33:33:ff:00:00:02")
        #expect(ns.p.payload == sealedLike(ns.p)(.ndp(NdpMessage(body: .ns(target: try parseIp6("2001:db8::2"), slla: "02:00:00:00:00:01")))))
        let na = try #require(sent(sim, by: "B").first { $0.time >= 2 * S })
        #expect(formatIp6(na.p.dst) == "2001:db8::1" && na.dst == "02:00:00:00:00:01")
        #expect(na.p.payload == sealedLike(na.p)(.ndp(NdpMessage(body: .na(target: try parseIp6("2001:db8::2"), router: false, solicited: true,
                                                                                override: true, tlla: "02:00:00:00:00:02")))))
        #expect(neighbors(a) == ["2001:db8::2 02:00:00:00:00:02 REACH"])
        #expect(neighbors(b) == ["2001:db8::1 02:00:00:00:00:01 DELAY"]) // learned STALE from the NS, then used for the NA
        sim.run(4890 * MS) // 6.99 s
        #expect(neighbors(b) == ["2001:db8::1 02:00:00:00:00:01 DELAY"])
        sim.run(110 * MS) // 7.1 s: PROBE at 7 s, a unicast NS, a solicited NA
        #expect(neighbors(b) == ["2001:db8::1 02:00:00:00:00:01 REACH"])
        let probe = try #require(sent(sim, by: "B").last { if case .ndp(let n) = $0.p.payload { n.type == ND_NS } else { false } })
        #expect(probe.time > 7 * S && formatIp6(probe.p.dst) == "2001:db8::1" && probe.dst == "02:00:00:00:00:01")
        sim.run(30 * S) // 37.1 s: A's entry has been REACH since 2 s
        #expect(neighbors(a) == ["2001:db8::2 02:00:00:00:00:02 STALE"])
    }

    @Test func anUnansweredAddressFailsAfterThreeSolicitationsWithAddressUnreachable() throws {
        let (sim, a, _) = try pair()
        let ping = try Ping(node: a, target: "2001:db8::9", options: PingOptions(count: 1))
        sim.run(5 * S)
        #expect(ndp(sim, by: "A", ND_NS).filter { $0 >= 2 * S } == [2 * S, 3 * S, 4 * S])
        #expect(drops(sim, .ndTimeout) == 1)
        #expect(ping.result.lines.contains("From 2001:db8::1 icmp_seq=1 Destination unreachable: Address unreachable"))
        #expect(neighbors(a).isEmpty)
    }

    @Test func aNeighbourThatStopsAnsweringIsProbedThreeTimesThenForgotten() throws {
        let (sim, a, b) = try pair()
        _ = try Ping(node: a, target: "2001:db8::2", options: PingOptions(count: 1))
        sim.run(38 * S) // 40 s: A's entry has been STALE since 32 s
        b.powered = false
        b.reset()
        _ = try Ping(node: a, target: "2001:db8::2", options: PingOptions(count: 1))
        sim.run(5 * S - 1)
        #expect(neighbors(a) == ["2001:db8::2 02:00:00:00:00:02 DELAY"])
        sim.run(2500 * MS + 1) // 47.5 s
        #expect(neighbors(a) == ["2001:db8::2 02:00:00:00:00:02 PROBE"])
        let probes = sent(sim, by: "A").filter { $0.time > 40 * S && formatIp6($0.p.dst) == "2001:db8::2" && $0.time != 40 * S }
        #expect(probes.map(\.time) == [45 * S, 46 * S, 47 * S])
        sim.run(1 * S) // 48.5 s
        #expect(neighbors(a).isEmpty)
    }

    @Test func ndpFromBeyondTheLinkIsIgnored() throws {
        let (sim, a, b) = try pair()
        let target = try parseIp6("2001:db8::2")
        let ns = makeIpv6(src: try parseIp6("2001:db8::1"), dst: solicitedNode(target), hopLimit: 64,
                          payload: .ndp(NdpMessage(body: .ns(target: target, slla: try a.iface("eth0").mac))))
        b.v6.input(ns, on: try b.iface("eth0"))
        sim.run(1 * S)
        #expect(sent(sim, by: "B").filter { $0.time >= 2 * S }.isEmpty && neighbors(b).isEmpty)
    }

    @Test func aPacketOverTheMtuIsNotFragmentedAndTheSenderGetsPacketTooBig() throws {
        let (sim, a, _) = try pair()
        let ping = try Ping(node: a, target: "2001:db8::2", options: PingOptions(count: 1, size: 1500))
        sim.run(1 * S)
        #expect(ping.result.lines.contains("From 2001:db8::1 icmp_seq=1 Packet too big: mtu=1500"))
        #expect(drops(sim, .mtuExceeded) == 1)
    }

    @Test func pingRefusesLinkLocalMulticastAndMalformedIpv6Targets() throws {
        let (_, a, _) = try pair()
        expectError("Ping to link-local or multicast addresses is not supported") { _ = try Ping(node: a, target: "fe80::1") }
        expectError("Ping to link-local or multicast addresses is not supported") { _ = try Ping(node: a, target: "ff02::1") }
        expectError("Invalid IPv6 address: \"2001:db8::g\"") { _ = try Ping(node: a, target: "2001:db8::g") }
    }

    @Test func theRouterAdvertisesAfterDadAndTheHostAutoconfigures() throws {
        let (sim, h1, r1) = try edge()
        sim.run(1 * S)
        #expect(ndp(sim, by: "R1", ND_RA) == [1 * S] && ndp(sim, by: "H1", ND_RS) == [1 * S])
        let ra = try #require(sent(sim, by: "R1").last)
        #expect(formatIp6(ra.p.src) == "fe80::ff:fe00:2" && formatIp6(ra.p.dst) == "ff02::1" && ra.p.hopLimit == 255)
        #expect(ra.p.payload == sealedLike(ra.p)(.ndp(NdpMessage(body: .ra(RouterAdvert(
            slla: try r1.iface("Gi0/0").mac, prefixes: [PrefixInfo(prefix: try parseIp6("2001:db8:1::"), length: 64)]))))))
        let rs = try #require(sent(sim, by: "H1").last)
        #expect(formatIp6(rs.p.src) == "fe80::ff:fe00:1" && formatIp6(rs.p.dst) == "ff02::2" && rs.dst == "33:33:00:00:00:02")
        sim.run(1 * MS) // the RA has arrived
        #expect(states(h1) == ["fe80::ff:fe00:1 preferred", "2001:db8:1::ff:fe00:1 tentative"])
        #expect(h1.v6.lookup(ELSEWHERE).map { "\($0.iface.name) \(formatIp6($0.nextHop))" } == "eth0 fe80::ff:fe00:2")
        #expect(neighbors(h1) == ["fe80::ff:fe00:2 02:00:00:00:00:02 STALE"]) // learned from the RA
        sim.run(1 * S)
        #expect(states(h1).last == "2001:db8:1::ff:fe00:1 preferred")
        sim.run(10 * S)
        #expect(ndp(sim, by: "R1", ND_RA) == [1 * S, 4 * S]) // the RS waited out MIN_DELAY_BETWEEN_RAS
        #expect(ndp(sim, by: "H1", ND_RS) == [1 * S]) // the RA stopped the solicitations
        sim.run(200 * S)
        #expect(ndp(sim, by: "R1", ND_RA) == [1 * S, 4 * S, 204 * S])
    }

    @Test func solicitationsBackOffUntilARouterAdvertises() throws {
        let (sim, h1, r1) = try edge(routing: false)
        sim.run(70 * S)
        #expect(ndp(sim, by: "H1", ND_RS) == [1, 5, 13, 29, 61].map { $0 * S })
        #expect(ndp(sim, by: "R1", ND_RA).isEmpty && h1.v6.lookup(ELSEWHERE) == nil)
        r1.v6.setRouting(true)
        sim.run(100 * S)
        #expect(ndp(sim, by: "R1", ND_RA) == [70 * S] && ndp(sim, by: "H1", ND_RS).count == 5)
        #expect(states(h1).last == "2001:db8:1::ff:fe00:1 preferred")
        // Without a router the interval stops doubling at 3600 s.
        let (alone, _, _) = try edge(routing: false)
        alone.run(8000 * S)
        #expect(ndp(alone, by: "H1", ND_RS) == [1, 5, 13, 29, 61, 125, 253, 509, 1021, 2045, 4093, 7693].map { $0 * S })
    }

    @Test func theDefaultRouterLastsTheRouterLifetimeAndAFinalAdvertisementRemovesIt() throws {
        let (sim, h1, r1) = try edge()
        sim.run(10 * S)
        #expect(h1.v6.lookup(ELSEWHERE) != nil)
        r1.v6.setRouting(false) // 10 s: a last RA with lifetime 0
        sim.run(1 * MS)
        #expect(h1.v6.lookup(ELSEWHERE) == nil && ndp(sim, by: "R1", ND_RA).last == 10 * S)
        r1.v6.setRouting(true) // 10.001 s: advertises at once
        sim.run(10 * S)
        #expect(h1.v6.lookup(ELSEWHERE) != nil && ndp(sim, by: "R1", ND_RA).last == 10 * S + 1 * MS)
        r1.powered = false
        r1.reset()
        sim.run(1_789_999 * MS) // 1810.000 s: the RA of 10.001 s still counts
        #expect(h1.v6.lookup(ELSEWHERE) != nil)
        sim.run(2 * MS)
        #expect(h1.v6.lookup(ELSEWHERE) == nil)
        #expect(states(h1).last == "2001:db8:1::ff:fe00:1 preferred") // SLAAC addresses do not expire with the router
    }

    @Test func withoutSlaacTheHostLearnsOnlyTheDefaultRouterAndTurningItOnSolicitsAtOnce() throws {
        let (sim, h1, _) = try edge(slaac: false)
        sim.run(10 * S)
        #expect(states(h1) == ["fe80::ff:fe00:1 preferred"] && h1.v6.lookup(ELSEWHERE) != nil)
        try h1.v6.configure("eth0", Ipv6Config(autoconfig: true))
        sim.run(2 * S)
        #expect(ndp(sim, by: "H1", ND_RS) == [1 * S, 10 * S] && ndp(sim, by: "R1", ND_RA).count == 3)
        #expect(states(h1).last == "2001:db8:1::ff:fe00:1 preferred")
        try h1.v6.configure("eth0", Ipv6Config(autoconfig: false))
        #expect(states(h1) == ["fe80::ff:fe00:1 preferred"])
    }

    @Test func routersNeitherAutoconfigureNorLearnDefaultRoutes() throws {
        let sim = Sim()
        let r1 = Router(sim: sim, id: "R1", ports: 1)
        let r2 = Router(sim: sim, id: "R2", ports: 1)
        _ = try Link(sim: sim, try r1.iface("Gi0/0"), try r2.iface("Gi0/0"))
        try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:12::1/64"))
        try r2.v6.configure("Gi0/0", Ipv6Config(autoconfig: true)) // the runtime refuses this; the engine ignores RAs anyway
        for r in [r1, r2] { r.v6.setRouting(true) }
        sim.run(5 * S)
        #expect(ndp(sim, by: "R1", ND_RA).first == 1 * S)
        #expect(states(r2, "Gi0/0") == ["fe80::ff:fe00:2 preferred"] && r2.v6.lookup(ELSEWHERE) == nil)
    }

    @Test func pingsAndTracesAcrossTheRouterWhileIpv4KeepsWorking() throws {
        let (sim, h1, _, _) = try routed()
        let ping6 = try Ping(node: h1, target: H2)
        let ping4 = try Ping(node: h1, target: "10.0.2.10")
        sim.run(5 * S)
        #expect(ping6.result.lines.last == "4 packets transmitted, 4 received, 0% packet loss" && ping6.result.replies.allSatisfy { $0.ttl == 63 })
        #expect(ping4.result.lines.last == "4 packets transmitted, 4 received, 0% packet loss")
        let trace = try Traceroute(node: h1, target: H2)
        sim.run(5 * S)
        #expect(trace.result.lines.first == "traceroute to \(H2) (\(H2)), 30 hops max, 80 byte packets")
        #expect(trace.result.hops.map { $0.probes.map(\.from) } == [Array(repeating: "2001:db8:1::1", count: 3), Array(repeating: H2, count: 3)])
        #expect(trace.result.reached && trace.result.done)
    }

    @Test func theRouterAnswersExpiredHopLimitsAndMissingRoutes() throws {
        let (sim, h1, _, _) = try routed()
        let expired = try Ping(node: h1, target: H2, options: PingOptions(count: 1, ttl: 1))
        let nowhere = try Ping(node: h1, target: "2001:db8:9::1", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(expired.result.lines.contains("From 2001:db8:1::1 icmp_seq=1 Time exceeded: Hop limit"))
        #expect(nowhere.result.lines.contains("From 2001:db8:1::1 icmp_seq=1 Destination unreachable: No route"))
        #expect(drops(sim, .ttlExpired) == 1 && drops(sim, .noRoute) == 1)
    }

    @Test func staticRoutesCarryTrafficBetweenTwoRouters() throws {
        let (sim, h1, h2, r1, r2) = try twoRouters()
        try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:1::1/64"))
        try r1.v6.configure("Gi0/1", Ipv6Config(address: "2001:db8:12::1/64"))
        try r2.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:12::2/64"))
        try r2.v6.configure("Gi0/1", Ipv6Config(address: "2001:db8:2::1/64"))
        for r in [r1, r2] { r.v6.setRouting(true) }
        for h in [h1, h2] { try h.v6.configure("eth0", Ipv6Config(autoconfig: true)) }
        sim.run(3 * S)
        expectError("Next hop 2001:db8:13::2 is not in a connected IPv6 subnet") { try r1.v6.addStatic("2001:db8:2::/64", "2001:db8:13::2") }
        expectError("Next hop fe80::1 is not in a connected IPv6 subnet") { try r1.v6.addStatic("2001:db8:2::/64", "fe80::1") }
        try r1.v6.addStatic("2001:db8:2::/64", "2001:db8:12::2")
        try r2.v6.addStatic("2001:db8:1::/64", "2001:db8:12::1")
        let ping = try Ping(node: h1, target: H2, options: PingOptions(count: 1))
        sim.run(1 * S)
        #expect(ping.result.replies.map(\.ttl) == [62])
        try r1.v6.removeStatic("2001:db8:2::/64")
        #expect(r1.v6.lookup(try parseIp6("2001:db8:2::1")) == nil)
    }

    @Test func aStaticDefaultBeatsTheOneFromTheRaAndAConnectedPrefixBeatsBoth() throws {
        let (sim, h1, _, _) = try routed()
        let hop = { (dst: String) in h1.v6.lookup(try! parseIp6(dst)).map { formatIp6($0.nextHop) } }
        try withExtendedLifetime(sim) { // the nodes refer to their Sim `unowned`
            #expect(hop("2001:db8:9::1") == "fe80::ff:fe00:3")
            try h1.v6.addStatic("::/0", "2001:db8:1::99")
            #expect(hop("2001:db8:9::1") == "2001:db8:1::99" && hop("2001:db8:1::7") == "2001:db8:1::7")
        }
    }

    @Test func withoutUnicastRoutingTheRouterForwardsNothing() throws {
        let (sim, h1, _, r1) = try routed()
        r1.v6.setRouting(false)
        try h1.v6.addStatic("::/0", "2001:db8:1::1") // the RA's default is gone with the final RA
        let ping = try Ping(node: h1, target: H2, options: PingOptions(count: 1, timeoutNs: 2 * S))
        sim.run(3 * S)
        #expect(ping.result.lines.last == "1 packets transmitted, 0 received, 100% packet loss")
    }

    @Test func natAndTheFirewallLeaveIpv6Alone() throws {
        let (sim, h1, _, r1) = try routed()
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(defaultAction: .deny))
        r1.nat = try Nat(node: r1, config: NatConfig(inside: ["Gi0/0"], outside: "Gi0/1"))
        let ping6 = try Ping(node: h1, target: H2, options: PingOptions(count: 1))
        let ping4 = try Ping(node: h1, target: "10.0.2.10", options: PingOptions(count: 1, timeoutNs: 2 * S))
        sim.run(3 * S)
        #expect(ping6.result.replies.map(\.ttl) == [63])
        #expect(ping4.result.received == 0 && drops(sim, .firewallDefault) == 1)
    }

    @Test func ipv6RunsOnASubinterfaceBehindASwitchWithoutPortFast() throws {
        let sim = Sim()
        let h1 = Host(sim: sim, id: "H1")
        let sw = Switch(sim: sim, id: "SW1")
        let r1 = Router(sim: sim, id: "R1", ports: 1)
        _ = try Link(sim: sim, try h1.iface("eth0"), try sw.iface("Gi0/1"))
        _ = try Link(sim: sim, try r1.iface("Gi0/0"), try sw.iface("Gi0/8"))
        try sw.setSwitchport("Gi0/1", PortConfig(vlan: 10))
        try sw.setSwitchport("Gi0/8", PortConfig(mode: .trunk))
        try r1.addSubinterface("Gi0/0.10")
        try r1.v6.configure("Gi0/0.10", Ipv6Config(address: "2001:db8:10::1/64"))
        r1.v6.setRouting(true)
        try h1.v6.configure("eth0", Ipv6Config(autoconfig: true))
        sim.run(60 * S)
        #expect(states(h1).count == 1) // the RSs of 1, 5, 13 and 29 s died in spanning tree's 30 s
        sim.run(3 * S)
        #expect(states(h1).last == "2001:db8:10::ff:fe00:1 preferred") // the RS of 61 s got through
        #expect(sim.log.all.contains { $0.kind == .tx && $0.node == "R1" && $0.frame?.vlan == 10 && $0.frame?.etherType == ETHERTYPE_IPV6 })
    }
}

/// The payload as `makeIpv6` seals it for this packet's addresses (the checksum depends on them).
private func sealedLike(_ p: Ipv6Packet) -> (Ipv6Payload) -> Ipv6Payload {
    { makeIpv6(src: p.src, dst: p.dst, hopLimit: p.hopLimit, payload: $0).payload }
}
