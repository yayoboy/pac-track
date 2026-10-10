import Testing
@testable import PacEngine

/// PC (H1, SLAAC) — R1 (Gi0/0 2001:db8:1::1/64 | Gi0/1 2001:db8:2::1/64, `ipv6 unicast-routing`) — SRV (H2, 2001:db8:2::53/64), dual
/// stack from `routedPair` (10.0.1.10 and 10.0.2.10), run to t = 3 s. MACs: H1 …:01, H2 …:02, R1 Gi0/0 …:03, Gi0/1 …:04.
private func lab() throws -> (sim: Sim, pc: Host, srv: Host, r1: Router) {
    let (sim, pc, srv, r1) = try routedPair()
    try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:1::1/64"))
    try r1.v6.configure("Gi0/1", Ipv6Config(address: "2001:db8:2::1/64"))
    r1.v6.setRouting(true)
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
}
