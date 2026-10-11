import Testing
@testable import PacEngine

/// PC (H1, SLAAC) — R1 (Gi0/0 2001:db8:1::1/64 | Gi0/1 2001:db8:2::1/64, `ipv6 unicast-routing`) — SRV (H2, 2001:db8:2::53/64), dual
/// stack from `routedPair` (10.0.1.10 and 10.0.2.10), run to t = 3 s; R1 advertises `rdnss` if given. MACs: H1 …:01, H2 …:02, R1 Gi0/0
/// …:03, Gi0/1 …:04.
private func lab(rdnss: String? = nil) throws -> (sim: Sim, pc: Host, srv: Host, r1: Router) {
    let (sim, pc, srv, r1) = try routedPair()
    try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:1::1/64"))
    try r1.v6.configure("Gi0/1", Ipv6Config(address: "2001:db8:2::1/64"))
    r1.v6.setRouting(true)
    if let rdnss { r1.v6.rdnss = try parseIp6(rdnss) }
    try pc.v6.configure("eth0", Ipv6Config(autoconfig: true))
    try srv.v6.configure("eth0", Ipv6Config(address: "2001:db8:2::53/64"))
    sim.run(3 * S)
    return (sim, pc, srv, r1)
}

private let SRV = UInt128(0x2001_0DB8_0002) << 80 | 0x53 // 2001:db8:2::53
private let PC = "2001:db8:1::ff:fe00:1"

/// Every TCP segment received anywhere over IPv6, with its packet.
private func tcp6(_ sim: Sim) -> [(p: Ipv6Packet, t: TcpSegment)] {
    sim.log.all.compactMap { e in
        guard e.kind == .rx, case .ipv6(let p)? = e.frame?.payload, case .tcp(let t) = p.payload else { return nil }
        return (p, t)
    }
}

private func checksumHolds(_ p: Ipv6Packet) -> Bool {
    internetChecksum(pseudoHeader6(p.src, p.dst, p.payload.size, p.payload.nextHeader) + serializePayload(p)) == 0
}

/// srv1.lab has both records, the others one each; SRV's IPv4 address is 10.0.2.10.
private let records = [
    DnsRecord(name: "srv1.lab", ip: "2001:db8:2::53"),
    DnsRecord(name: "srv1.lab", ip: "10.0.2.10"),
    DnsRecord(name: "v4only.lab", ip: "10.0.2.10"),
    DnsRecord(name: "v6only.lab", ip: "2001:db8:2::53"),
]

/// The types of the DNS queries a node sent, over either stack, in order.
private func queries(_ sim: Sim, from node: String) -> [UInt16] {
    sim.log.all.compactMap { e -> UInt16? in
        guard e.kind == .tx, e.node == node else { return nil }
        var u: UdpDatagram?
        if case .ipv4(let p)? = e.frame?.payload, case .udp(let d) = p.payload { u = d }
        if case .ipv6(let p)? = e.frame?.payload, case .udp(let d) = p.payload { u = d }
        guard case .dns(let m)? = u?.payload, !m.response else { return nil }
        return m.type
    }
}

@Suite struct Ipv6ServicesTests {
    @Test func tcpOverIpv6HasItsWireSizeAPseudoHeaderChecksumAndItsLayers() throws {
        let src = try parseIp6("2001:db8:1::10")
        let syn = makeIpv6(src: src, dst: SRV, hopLimit: 64,
                           payload: .tcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1, ack: 0, flags: [.syn], window: 65535, mss: 1440)))
        let full = makeIpv6(src: src, dst: SRV, hopLimit: 64,
                            payload: .tcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 2, ack: 7, flags: [.ack], window: 65535, dataLength: 1440)))
        #expect(syn.size == 64 && full.size == 1500 && syn.payload.nextHeader == IPPROTO_TCP)
        #expect(checksumHolds(syn) && checksumHolds(full)) // the zero data is not serialized, but its length is in the pseudo-header
        let e = SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: EthernetFrame(
            id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV6, payload: .ipv6(syn)))
        #expect(eventView(e).proto == .tcp && eventView(e).bytes == 78)
        #expect(eventView(e).info == "TCP 40000 → 9 [SYN] seq=1 win=65535 len=0 mss=1440 · 2001:db8:1::10 → 2001:db8:2::53")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv6", "TCP"])
        #expect(layers[1].fields.contains(PduField(name: "Next header", value: "6 (TCP)")))
        #expect(layers[2].fields.contains(PduField(name: "Opzione MSS", value: "1440 B")))
    }

    @Test func tcpRunsOverIpv6WithAnMssOf1440AndResetsAClosedPort() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureSink(true)
        let c = try pc.tcp.connect(to: .v6(SRV), port: 9, sending: 100_000)
        sim.run(5 * S)
        #expect(try c.localIp == .v6(parseIp6(PC)) && c.remoteIp == .v6(SRV))
        #expect(c.bytesAcked == 100_000 && c.doneAt != nil)
        let segments = tcp6(sim)
        #expect(Set(segments.compactMap { $0.t.mss }) == [1440]) // both SYNs
        #expect(segments.map { $0.t.dataLength }.max() == 1440)
        #expect(segments.allSatisfy { checksumHolds($0.p) })
        #expect(drops(sim, .mtuExceeded) == 0)
        try srv.configureSink(false)
        let refused = try pc.tcp.connect(to: .v6(SRV), port: 9, sending: 1000)
        sim.run(1 * S)
        #expect(refused.failure == .refused)
    }

    @Test func udpPortsBoundOnBothStacksTakeIpv6AndTheOthersAnswerPortUnreachable() throws {
        let (sim, pc, srv, _) = try lab()
        var got: [String] = []
        let unbind = try srv.bindDualUdp(5000) { src, dst, u in got.append("\(src.text) → \(dst.text) port \(u.dstPort)") }
        var codes: [UInt8] = []
        pc.v6.onIcmp { _, m in if m.type == ICMP6_DEST_UNREACH { codes.append(m.code) } }
        pc.v6.send(SRV, .udp(makeUdp(srcPort: 40000, dstPort: 5000, data: [1])))
        pc.v6.send(SRV, .udp(makeUdp(srcPort: 40000, dstPort: 5001, data: [1])))
        sim.run(1 * S)
        #expect(got == ["\(PC) → 2001:db8:2::53 port 5000"])
        #expect(codes == [UNREACH6_PORT])
        expectError("UDP port 5000 already in use") { try srv.bindUdp(5000) { _, _, _ in } }
        unbind()
        try srv.bindUdp(5000) { _, _, _ in }
    }

    /// M9a review: "fe80::1%eth0" said "Invalid IPv6 address" instead of the typed error.
    @Test func zonesGetTheLinkLocalErrorAndNothingElse() throws {
        let sim = Sim()
        let a = Host(sim: sim, id: "A")
        withExtendedLifetime(sim) {
            expectError("Ping to link-local or multicast addresses is not supported") { _ = try Ping(node: a, target: "fe80::1%eth0") }
            expectError("Traceroute to link-local or multicast addresses is not supported") { _ = try Traceroute(node: a, target: "ff02::1%eth0") }
            expectError("Invalid IPv6 address: \"2001:db8::1%eth0\"") { _ = try Ping(node: a, target: "2001:db8::1%eth0") }
            expectError("Invalid IPv6 address: \"fe80::zz\"") { _ = try Ping(node: a, target: "fe80::zz%eth0") } // the address part is parsed first
        }
    }

    @Test func theTrafficGeneratorRunsTcpAndUdpToAnIpv6Address() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureSink(true)
        let tcp = try TcpFlow(node: pc, target: "2001:db8:2::53", bytes: 100_000)
        let udp = try UdpFlow(node: pc, target: "2001:DB8:2::53", bitsPerSecond: 1e6, seconds: 1)
        sim.run(4 * S)
        #expect(tcp.result.lines.first == "Connecting to host 2001:db8:2::53, port 9")
        #expect(tcp.result.lines[1].hasPrefix("[  1] local \(PC) port ") && tcp.result.lines[1].hasSuffix(" connected to 2001:db8:2::53 port 9"))
        #expect(tcp.result.lines.last == "iperf Done.")
        #expect(udp.result.lines.contains { $0.hasSuffix("0/87 (0%)") }) // 1450 B every 11.6 ms for 1 s
        #expect(udp.result.lines.last == "iperf Done.")
        #expect(sim.log.all.contains { $0.kind == .rx && $0.node == "H2" && $0.frame?.size == 1512 }) // 14 + 40 + 8 + 1450
        #expect(drops(sim, .mtuExceeded) == 0)
        expectError("Traffic to link-local or multicast addresses is not supported") { _ = try TcpFlow(node: pc, target: "fe80::1", bytes: 1) }
    }

    @Test func aaaaQuestionsAndAnswersHaveTheirWireSizesAndLayers() throws {
        let q = DnsMessage(id: 1, response: false, name: "srv1.lab", type: DNS_TYPE_AAAA)
        #expect(q.size == 26) // header 12 + name 10 + type/class 4
        let r = DnsMessage(id: 1, response: true, authoritative: true, name: "srv1.lab", answers: [DnsAnswer(ttl: 3600, addr: SRV)], type: DNS_TYPE_AAAA)
        #expect(r.size == 54) // + 28: pointer, type, class, TTL, length, 16 B of address
        let p = makeIpv6(src: SRV, dst: try parseIp6(PC), hopLimit: 64, payload: .udp(makeUdp(srcPort: 53, dstPort: 40000, payload: .dns(r))))
        let e = SimEvent(time: 0, kind: .tx, node: "S", iface: "eth0", frame: EthernetFrame(
            id: 1, src: "02:00:00:00:00:02", dst: "02:00:00:00:00:04", etherType: ETHERTYPE_IPV6, payload: .ipv6(p)))
        #expect(eventView(e).proto == .dns && eventView(e).bytes == 116)
        #expect(eventView(e).info == "DNS Risposta 0x0001 AAAA srv1.lab → 2001:db8:2::53 · 2001:db8:2::53 → \(PC)")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv6", "UDP", "DNS"])
        #expect(layers[3].fields.contains(PduField(name: "Domanda", value: "srv1.lab tipo AAAA, classe IN")))
        #expect(layers[3].fields.contains(PduField(name: "Risposta 1", value: "srv1.lab AAAA 2001:db8:2::53, TTL 3600 s")))
    }

    @Test func theServerAnswersAaaaOnBothStacksAndNslookupShowsAAndAaaa() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureDnsServer(records)
        pc.nameServer = try parseIp("10.0.2.10")
        // One at a time at first: ARP queues at most 3 packets for the gateway.
        let both = try NsLookup(node: pc, name: "srv1.lab")
        sim.run(1 * S)
        let v4 = try NsLookup(node: pc, name: "v4only.lab")
        let v6 = try NsLookup(node: pc, name: "v6only.lab")
        sim.run(1 * S)
        let missing = try NsLookup(node: pc, name: "nope.lab")
        sim.run(1 * S)
        #expect(both.result.lines == ["Server:\t\t10.0.2.10", "Address:\t10.0.2.10#53", "",
                                     "Name:\tsrv1.lab", "Address: 10.0.2.10", "Name:\tsrv1.lab", "Address: 2001:db8:2::53", ""])
        #expect(Array(v4.result.lines.suffix(3)) == ["Name:\tv4only.lab", "Address: 10.0.2.10", ""]) // the AAAA got NODATA
        #expect(Array(v6.result.lines.suffix(3)) == ["Name:\tv6only.lab", "Address: 2001:db8:2::53", ""])
        #expect(Array(missing.result.lines.suffix(2)) == ["** server can't find nope.lab: NXDOMAIN", ""])
        #expect(queries(sim, from: "H1") == [DNS_TYPE_A, DNS_TYPE_AAAA, DNS_TYPE_A, DNS_TYPE_A, DNS_TYPE_AAAA, DNS_TYPE_AAAA, DNS_TYPE_A])
        // Over IPv6 the server answers from the address it was asked.
        var answers: [Resolution] = []
        pc.resolver.lookup("srv1.lab", server: .v6(SRV), type: DNS_TYPE_AAAA, useCache: false) { answers.append($0) }
        sim.run(1 * S)
        #expect(answers == [.found([.v6(SRV)])])
        expectError("Record srv1.lab AAAA 2001:db8:2::53 already exists") {
            try srv.configureDnsServer(records + [DnsRecord(name: "SRV1.lab", ip: "2001:DB8:2:0::53")])
        }
        expectError("Invalid IPv6 address") { try srv.configureDnsServer([DnsRecord(name: "a.lab", ip: "2001:db8::zz")]) }
    }

    @Test func namesResolveToTheAaaaOnlyWhenTheDeviceHasAGlobalIpv6Address() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureDnsServer(records)
        pc.nameServer = try parseIp("10.0.2.10")
        let ping6 = try Ping(node: pc, target: "srv1.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping6.result.lines.first == "PING srv1.lab(2001:db8:2::53) 56 data bytes")
        #expect(ping6.result.replies.map(\.ttl) == [63])
        #expect(queries(sim, from: "H1") == [DNS_TYPE_A, DNS_TYPE_AAAA]) // back to back, like glibc
        #expect(pc.resolver.entries().map(\.type) == [DNS_TYPE_A, DNS_TYPE_AAAA])
        let ping4 = try Ping(node: pc, target: "v4only.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping4.result.lines.first == "PING v4only.lab (10.0.2.10) 56(84) bytes of data.")
        // Without a global IPv6 address only the A is asked, as before M9b.
        try pc.v6.configure("eth0", nil)
        let trace = try Traceroute(node: pc, target: "v6only.lab")
        sim.run(1 * S)
        #expect(trace.result.lines.first == "v6only.lab: Name or service not known")
        #expect(queries(sim, from: "H1").suffix(1) == [DNS_TYPE_A] && queries(sim, from: "H1").count == 5)
    }

    @Test func routersAdvertiseTheirDnsServerAndHostsUseItLast() throws {
        let (sim, pc, srv, r1) = try lab(rdnss: "2001:db8:2::53")
        try srv.configureDnsServer(records)
        #expect(pc.v6.dnsServer == SRV && pc.effectiveNameServer == .v6(SRV))
        // The RA's RDNSS option: after the prefix, 24 B, lifetime 600 s.
        let ras = sim.log.all.compactMap { e -> Ipv6Packet? in
            guard e.kind == .tx, e.node == "R1", e.iface == "Gi0/0", case .ipv6(let p)? = e.frame?.payload, case .ndp(let n) = p.payload,
                  n.type == ND_RA else { return nil }
            return p
        }
        #expect(ras.map(\.size) == [128]) // the RA of 1 s: 40 + 16 + SLLA 8 + MTU 8 + one prefix 32 + RDNSS 24
        #expect(Array(serializePayload(ras[0]).suffix(24)) == [25, 3, 0, 0, 0, 0, 0x02, 0x58] + bytes16(SRV))
        let ping = try Ping(node: pc, target: "srv1.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping.result.lines.first == "PING srv1.lab(2001:db8:2::53) 56 data bytes" && ping.result.received == 1)
        #expect(sim.log.all.contains { e in
            guard e.kind == .tx, e.node == "H1", case .ipv6(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .dns = u.payload else { return false }
            return p.dst == SRV
        })
        // A server typed by hand comes first.
        pc.nameServer = try parseIp("10.0.2.10")
        #expect(try pc.effectiveNameServer == .v4(parseIp("10.0.2.10")))
        pc.nameServer = nil
        // The router stops advertising it: it lasts 600 s from the last RA that carried it (the answer to the RSs, at 4 s).
        r1.v6.rdnss = nil
        sim.run(604 * S - 1 - sim.now)
        #expect(pc.v6.dnsServer == SRV)
        sim.run(1 * S)
        #expect(pc.v6.dnsServer == nil && pc.effectiveNameServer == nil)
        // Lifetime 0 withdraws it at once.
        let ll = linkLocal("02:00:00:00:00:03")
        let ra = { (lifetime: UInt32) in makeIpv6(src: ll, dst: ALL_NODES, hopLimit: 255, payload: .ndp(NdpMessage(body: .ra(RouterAdvert(
            slla: "02:00:00:00:00:03", prefixes: [], dns: SRV, dnsLifetime: lifetime))))) }
        pc.v6.input(ra(600), on: try pc.iface("eth0"))
        #expect(pc.v6.dnsServer == SRV)
        pc.v6.input(ra(0), on: try pc.iface("eth0"))
        #expect(pc.v6.dnsServer == nil)
    }
}
