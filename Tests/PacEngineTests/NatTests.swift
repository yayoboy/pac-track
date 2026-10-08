import Testing
@testable import PacEngine

/// H1 (192.168.1.10/24) and H2 (192.168.2.10/24) inside R1 (Gi0/0 192.168.1.1 and Gi0/2 192.168.2.1: inside; Gi0/1 203.0.113.1/24:
/// outside); SRV (203.0.113.10/24) outside, with no route back to the private networks.
private func natLab() throws -> (sim: Sim, h1: Host, h2: Host, r1: Router, srv: Host) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let srv = Host(sim: sim, id: "SRV")
    let r1 = Router(sim: sim, id: "R1", ports: 3)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try srv.iface("eth0"))
    _ = try Link(sim: sim, try h2.iface("eth0"), try r1.iface("Gi0/2"))
    try r1.setIp("Gi0/0", "192.168.1.1/24")
    try r1.setIp("Gi0/1", "203.0.113.1/24")
    try r1.setIp("Gi0/2", "192.168.2.1/24")
    try h1.setIp("eth0", "192.168.1.10/24")
    try h1.setGateway("192.168.1.1")
    try h2.setIp("eth0", "192.168.2.10/24")
    try h2.setGateway("192.168.2.1")
    try srv.setIp("eth0", "203.0.113.10/24")
    r1.nat = try Nat(node: r1, config: NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/1"))
    return (sim, h1, h2, r1, srv)
}

private struct Got: Equatable {
    let from: String
    let port: UInt16
    let checksumOk: Bool
}

private final class UdpLog {
    var got: [Got] = []
}

/// Records what reaches a UDP port (source, source port, IPv4 header checksum valid); `echo` answers each datagram.
private func listen(_ node: IpNode, _ port: UInt16, echo: Bool = false) throws -> UdpLog {
    let log = UdpLog()
    try node.bindUdp(port) { p, u, _ in
        log.got.append(Got(from: formatIp(p.src), port: u.srcPort, checksumOk: internetChecksum(serializeHeader(p)) == 0))
        if echo { node.sendUdp(p.src, srcPort: port, dstPort: u.srcPort, data: [1]) }
    }
    return log
}

/// ICMP errors a host received: the quoted bytes, and whether every outer IPv4 checksum held.
private final class Errors {
    var quotes: [[UInt8]] = []
    var headersOk = true
}

/// Every packet received anywhere carries valid checksums: the IPv4 header, ICMP (and the IPv4 header an error quotes), TCP over its
/// pseudo-header, UDP 0 (not computed, RFC 768).
private func checksumsHold(_ sim: Sim) -> Bool {
    sim.log.all.filter { $0.kind == .rx }.allSatisfy { e in
        guard case .ipv4(let p)? = e.frame?.payload else { return true }
        guard internetChecksum(serializeHeader(p)) == 0 else { return false }
        switch p.payload {
        case .icmp(let m):
            return internetChecksum(serialize(m)) == 0 && (quotedEndpoints(m) == nil || internetChecksum(Array(m.data[0..<20])) == 0)
        case .tcp(let t): return makeTcp(t, src: p.src, dst: p.dst).checksum == t.checksum
        case .udp(let u): return u.checksum == 0
        }
    }
}

@Suite struct NatTests {
    @Test func rewritingRecomputesTheChecksumsAndAnErrorQuoteGetsItsSourceBack() throws {
        let (a, b, g) = (try parseIp("192.168.1.10"), try parseIp("203.0.113.10"), try parseIp("203.0.113.1"))
        let syn = makeTcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1000, ack: 0, flags: [.syn], window: 65535, mss: 1460), src: a, dst: b)
        let q = rewritten(makeIpv4(src: a, dst: b, ttl: 64, id: 1, payload: .tcp(syn)), src: g, srcPort: 1024)
        guard case .tcp(let t) = q.payload else {
            Issue.record("not TCP")
            return
        }
        #expect(q.src == g && q.dst == b && t.srcPort == 1024 && t.dstPort == 9)
        #expect(internetChecksum(serializeHeader(q)) == 0)
        #expect(t.checksum == makeTcp(t, src: g, dst: b).checksum && t.checksum != syn.checksum) // the pseudo-header changed
        let echo = makeIpv4(src: a, dst: b, ttl: 64, id: 2, payload: echoRequest())
        guard case .icmp(let m) = rewritten(echo, srcPort: 77).payload else {
            Issue.record("not ICMP")
            return
        }
        #expect(m.id == 77 && internetChecksum(serialize(m)) == 0)
        #expect(endpoints(echo) == Endpoints(proto: IPPROTO_ICMP, src: a, srcPort: 9, dst: b, dstPort: 0))
        // A router beyond the NAT quotes the translated echo; the NAT gives the quote back its inside source.
        let translated = rewritten(echo, src: g, srcPort: 77)
        let error = makeIcmp(type: ICMP_TIME_EXCEEDED, code: 0, id: 0, seq: 0, data: serializeHeader(translated) + serializeL4(translated).prefix(8))
        #expect(quotedEndpoints(error) == Endpoints(proto: IPPROTO_ICMP, src: g, srcPort: 77, dst: b, dstPort: 0))
        let back = withQuotedSource(error, a, 9)
        #expect(quotedEndpoints(back) == Endpoints(proto: IPPROTO_ICMP, src: a, srcPort: 9, dst: b, dstPort: 0))
        #expect(internetChecksum(Array(back.data[0..<20])) == 0) // quoted IPv4 header
        #expect(internetChecksum(Array(back.data[20..<28])) == 0) // quoted echo header (its 56 data bytes are zeros)
        #expect(internetChecksum(serialize(back)) == 0)
    }

    @Test func udpLeavesFromTheOutsideAddressKeepingItsPortAndTheReplyFindsItsWayBack() throws {
        let (sim, h1, _, r1, srv) = try natLab()
        let atSrv = try listen(srv, 7, echo: true)
        let atH1 = try listen(h1, 5000)
        h1.sendUdp(try parseIp("203.0.113.10"), srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        #expect(atSrv.got == [Got(from: "203.0.113.1", port: 5000, checksumOk: true)])
        #expect(atH1.got == [Got(from: "203.0.113.10", port: 7, checksumOk: true)])
        let table = try #require(r1.nat?.view())
        #expect(table.count == 1)
        let e = table[0]
        #expect(e.proto == IPPROTO_UDP && formatIp(e.local) == "192.168.1.10" && e.localPort == 5000)
        #expect(formatIp(e.global) == "203.0.113.1" && e.globalPort == 5000 && formatIp(e.remote) == "203.0.113.10" && e.remotePort == 7)
        #expect(e.expiresAt > sim.now + 299 * S) // 300 s from the reply
        #expect(checksumsHold(sim))
        sim.run(300 * S)
        #expect(r1.nat?.view().isEmpty == true)
    }

    @Test func twoHostsOnTheSamePortGetDifferentGlobalPortsAndOnlyTheContactedEndpointGetsBack() throws {
        let (sim, h1, h2, r1, srv) = try natLab()
        let at7 = try listen(srv, 7)
        let at8 = try listen(srv, 8)
        let atH1 = try listen(h1, 5000)
        let dst = try parseIp("203.0.113.10")
        h1.sendUdp(dst, srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        h2.sendUdp(dst, srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        h1.sendUdp(dst, srcPort: 5000, dstPort: 8, data: [0])
        sim.run(10 * MS)
        #expect(at7.got.map(\.port) == [5000, 5001]) // H2 found 5000 taken: the next free port
        #expect(at8.got.map(\.port) == [5000]) // H1 keeps its mapping for every remote (RFC 4787 REQ-1)
        #expect(r1.nat?.view().map { "\($0.localPort)→\($0.globalPort):\($0.remotePort)" } == ["5000→5000:7", "5000→5001:7", "5000→5000:8"])
        // Only the endpoint H1 contacted gets back in; the other datagram is the router's own and closed.
        let global = try parseIp("203.0.113.1")
        srv.sendUdp(global, srcPort: 9, dstPort: 5000, data: [0])
        srv.sendUdp(global, srcPort: 7, dstPort: 5000, data: [0])
        sim.run(10 * MS)
        #expect(atH1.got == [Got(from: "203.0.113.10", port: 7, checksumOk: true)])
        let unreachable = sim.log.all.filter {
            $0.kind == .tx && $0.node == "R1" && eventView($0).info == "203.0.113.1 → 203.0.113.10 Destination unreachable (port) ttl=255"
        }
        #expect(unreachable.count == 1)
        #expect(checksumsHold(sim))
    }

    @Test func pingAndTracerouteFromInsideWorkAndIcmpErrorsComeBackTranslated() throws {
        let (sim, h1, _, r1, _) = try natLab()
        let errors = Errors()
        h1.onIcmp { p, m in
            guard m.type == ICMP_DEST_UNREACH else { return }
            errors.quotes.append(m.data)
            errors.headersOk = errors.headersOk && internetChecksum(serializeHeader(p)) == 0
        }
        let ping = try Ping(node: h1, target: "203.0.113.10")
        sim.run(5 * S)
        #expect(ping.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        let echo = try #require(r1.nat?.view().first { $0.proto == IPPROTO_ICMP })
        #expect(echo.globalPort == echo.localPort && echo.remotePort == 0) // the echo identifier is kept
        let trace = try Traceroute(node: h1, target: "203.0.113.10")
        sim.run(5 * S)
        #expect(trace.result.done)
        #expect(trace.result.lines[1].hasPrefix(" 1  192.168.1.1 (192.168.1.1)"))
        #expect(trace.result.lines[2].hasPrefix(" 2  203.0.113.10 (203.0.113.10)"))
        // SRV's port unreachable quoted the translated probe; R1 put the inside source back and fixed the quoted checksum.
        let q = try #require(errors.quotes.first)
        #expect(errors.quotes.count == 3 && errors.headersOk)
        #expect(Array(q[12..<16]) == [192, 168, 1, 10] && internetChecksum(Array(q[0..<20])) == 0)
        #expect(checksumsHold(sim)) // the echoes, the probes, the Time Exceeded and the translated port unreachables
    }

    @Test func tcpCrossesWithRecomputedChecksumsAndItsTranslationEndsAMinuteAfterTheFin() throws {
        let (sim, h1, _, r1, srv) = try natLab()
        try srv.configureSink(true)
        let flow = try TcpFlow(node: h1, target: "203.0.113.10", bytes: 100_000)
        sim.run(1 * S)
        #expect(flow.result.lines.last == "iperf Done.")
        let atSrv = sim.log.all.filter { $0.kind == .rx && $0.node == "SRV" }.compactMap { e -> (Ipv4Packet, TcpSegment)? in
            guard case .ipv4(let p)? = e.frame?.payload, case .tcp(let t) = p.payload else { return nil }
            return (p, t)
        }
        #expect(!atSrv.isEmpty)
        #expect(atSrv.allSatisfy { formatIp($0.0.src) == "203.0.113.1" && makeTcp($0.1, src: $0.0.src, dst: $0.0.dst).checksum == $0.1.checksum })
        let tcp = try #require(r1.nat?.view().first { $0.proto == IPPROTO_TCP })
        #expect(tcp.closing && tcp.expiresAt <= sim.now + 60 * S)
        #expect(checksumsHold(sim)) // both directions, H1's side included
        sim.run(60 * S)
        #expect(r1.nat?.view().isEmpty == true)
    }

    @Test func unsolicitedPacketsToTheOutsideAddressAreTheRoutersOwnAndAPowerCycleClearsTheTable() throws {
        let (sim, h1, _, r1, srv) = try natLab()
        let ping = try Ping(node: srv, target: "203.0.113.1")
        let refused = try TcpFlow(node: srv, target: "203.0.113.1", bytes: 1000)
        sim.run(4 * S)
        #expect(ping.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(refused.result.lines.last == "iperf3: error - unable to connect to server: Connection refused")
        #expect(r1.nat?.view().isEmpty == true)
        #expect(!sim.log.all.contains { $0.node == "H1" && $0.kind == .rx })
        h1.sendUdp(try parseIp("203.0.113.10"), srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        #expect(r1.nat?.view().count == 1)
        r1.reset()
        #expect(r1.nat?.view().isEmpty == true)
        #expect(r1.nat?.config == NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/1"))
    }

    @Test func fragmentationNeededBeyondTheNatReachesTheInsideHost() throws {
        let (sim, h1, _, r1, _) = try natLab()
        try r1.iface("Gi0/1").mtu = 1000
        let ping = try Ping(node: h1, target: "203.0.113.10", options: PingOptions(count: 1, size: 1200))
        sim.run(1 * S)
        let unreachable = ping.result.lines.contains { $0.contains("192.168.1.1") && $0.contains("Frag needed") }
        #expect(unreachable, "\(ping.result.lines)")
        #expect(r1.nat?.view().isEmpty == true) // the dropped request opened no translation
    }

    @Test func rejectsUnknownInterfacesAndAnInterfaceBothInsideAndOutside() throws {
        let (_, _, _, r1, _) = try natLab()
        expectError("R1 has no interface Gi0/9") { _ = try Nat(node: r1, config: NatConfig(inside: ["Gi0/9"], outside: "Gi0/1")) }
        expectError("Gi0/1 cannot be both inside and outside") { _ = try Nat(node: r1, config: NatConfig(inside: ["Gi0/1"], outside: "Gi0/1")) }
    }
}
