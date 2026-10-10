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
        #expect(sent(sim, by: "A").map(\.time) == [5 * S, 5 * S + 816] && states(a).last == "2001:db8::1 tentative")
        sim.run(1 * MS)
        #expect(states(a).last == "2001:db8::1 preferred")
        link.up = false
        sim.run(2 * S)
        #expect(states(a).last == "2001:db8::1 preferred") // a line going down changes nothing
        link.up = true
        #expect(states(a).last == "2001:db8::1 tentative")
        sim.run(1 * S)
        #expect(sent(sim, by: "A").map(\.time).suffix(2) == [8 * S, 8 * S + 816] && states(a).last == "2001:db8::1 preferred")
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
        #expect(sent(sim, by: "A").map(\.time).suffix(2) == [3 * S, 3 * S + 816] && states(a).last == "2001:db8::1 tentative")
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
        #expect(sent(sim, by: "A").filter { $0.time >= 2 * S }.map(\.time) == [2 * S, 3 * S, 4 * S])
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
}

/// The payload as `makeIpv6` seals it for this packet's addresses (the checksum depends on them).
private func sealedLike(_ p: Ipv6Packet) -> (Ipv6Payload) -> Ipv6Payload {
    { makeIpv6(src: p.src, dst: p.dst, hopLimit: p.hopLimit, payload: $0).payload }
}
