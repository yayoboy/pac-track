import Testing
@testable import PacEngine

/// In-line two-port cable joint that drops the frames `lose` picks: deterministic loss.
private final class Tap: Node {
    var lose: (EthernetFrame) -> Bool = { _ in false }

    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("p0")
        addInterface("p1")
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        if lose(frame) { return sim.emit(.drop, node: id, iface: iface.name, frame: frame, reason: .loss) }
        interfaces.first { $0 !== iface }!.send(frame)
    }
}

/// H1 (10.0.0.1/24) — tap — H2 (10.0.0.2/24), both cables 1 Gb/s.
private func tapped() throws -> (sim: Sim, h1: Host, h2: Host, tap: Tap) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let tap = Tap(sim: sim, id: "T")
    _ = try Link(sim: sim, try h1.iface("eth0"), try tap.iface("p0"))
    _ = try Link(sim: sim, try tap.iface("p1"), try h2.iface("eth0"))
    try h1.setIp("eth0", "10.0.0.1/24")
    try h2.setIp("eth0", "10.0.0.2/24")
    return (sim, h1, h2, tap)
}

private func tcpOf(_ frame: EthernetFrame) -> TcpSegment? {
    guard case .ipv4(let p) = frame.payload, case .tcp(let t) = p.payload else { return nil }
    return t
}

/// TCP segments `node` started putting on the wire, in order.
private func segments(_ sim: Sim, _ node: String) -> [(time: Int, seg: TcpSegment)] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node, let t = e.frame.flatMap(tcpOf) else { return nil }
        return (e.time, t)
    }
}

/// tcpdump-style flags ("S", "S.", ".", "F.", "R.") plus the data length.
private func label(_ t: TcpSegment) -> String {
    let marks: [(TcpFlags, String)] = [(.syn, "S"), (.fin, "F"), (.rst, "R"), (.ack, ".")]
    return marks.filter { t.flags.contains($0.0) }.map { $0.1 }.joined() + (t.dataLength > 0 ? " \(t.dataLength)" : "")
}

@Suite struct TcpTests {
    @Test func connectsWithAThreeWayHandshakeSendsTheDataAndClosesWithFin() throws {
        let (sim, h1, h2, _) = try tapped()
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim.run(10 * MS)
        let a = segments(sim, "H1").map { $0.seg }
        let b = segments(sim, "H2").map { $0.seg }
        #expect(a.map(label) == ["S", ".", ". 1460", ". 1460", ". 80", "F.", "."])
        #expect(b.map(label) == ["S.", ".", ".", ".", "F."])
        let isn = a[0].seq
        let peer = b[0].seq
        #expect(a[0].mss == 1460 && b[0].mss == 1460 && a[1].mss == nil)
        #expect(a.allSatisfy { $0.window == 65535 } && b.allSatisfy { $0.window == 65535 })
        #expect(b[0].ack == isn &+ 1) // the SYN-ACK acknowledges the SYN…
        #expect(a[1].ack == peer &+ 1) // …and the ACK the SYN-ACK
        #expect(a[2...4].map { $0.seq &- isn } == [1, 1461, 2921]) // data numbered from ISN + 1
        #expect(b[1...3].map { $0.ack &- isn } == [1461, 2921, 3001]) // every segment acknowledged at once
        #expect(a[5].seq &- isn == 3001 && b[4].ack &- isn == 3002) // the FIN takes one sequence number
        #expect(a[6].ack == peer &+ 2)
        #expect(c.state == .timeWait && c.bytesAcked == 3000 && c.failure == nil)
        #expect(h2.tcp.connections.isEmpty) // LAST_ACK → CLOSED on the final ACK
        #expect(h1.tcp.connections.map(\.state) == [.timeWait])
        sim.run(60 * S)
        #expect(h1.tcp.connections.isEmpty && c.state == .closed)
        // The ISN comes from the seeded PRNG: same seed, same ISN.
        let (sim2, h1b, h2b, _) = try tapped()
        try h2b.tcp.listen(9)
        _ = try h1b.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim2.run(1 * MS)
        #expect(segments(sim2, "H1").first?.seg.seq == isn)
    }

    @Test func aClosedPortAnswersTheSynWithARst() throws {
        let (sim, h1, _, _) = try tapped()
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1000)
        sim.run(1 * MS)
        let syn = segments(sim, "H1")[0].seg
        let rst = segments(sim, "H2").map { $0.seg }
        #expect(rst.map(label) == ["R."])
        #expect(rst[0].seq == 0 && rst[0].ack == syn.seq &+ 1 && rst[0].window == 0)
        #expect(c.state == .closed && c.failure == .refused && h1.tcp.connections.isEmpty)
    }

    @Test func retransmitsALostSynAfter1SecondDoublingTheTimeoutAndGivesUpAfter127Seconds() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        tap.lose = { tcpOf($0) != nil } // ARP gets through, TCP does not
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1000)
        sim.run(126 * S)
        let syns = segments(sim, "H1")
        #expect(syns.map { label($0.seg) } == Array(repeating: "S", count: 7))
        #expect(syns.allSatisfy { $0.seg.seq == syns[0].seg.seq })
        #expect(syns.dropFirst().map { $0.time } == [1, 3, 7, 15, 31, 63].map { $0 * S }) // connect at 0; RTO 1, 2, 4 … 64 s
        #expect(c.state == .synSent)
        sim.run(2 * S)
        #expect(c.state == .closed && c.failure == .timedOut) // the 7th timeout, at 127 s
    }

    @Test func aServerGivesUpOnAnUnansweredSynAckAfter5Retransmissions() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var first = true
        tap.lose = { f in // only the first SYN gets through
            guard tcpOf(f) != nil else { return false }
            defer { first = false }
            return !first
        }
        _ = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1000)
        sim.run(62 * S)
        let synAcks = segments(sim, "H2")
        #expect(synAcks.map { label($0.seg) } == Array(repeating: "S.", count: 6))
        #expect(synAcks.dropFirst().map { $0.time - synAcks[0].time } == [1, 3, 7, 15, 31].map { $0 * S }) // Linux tcp_synack_retries
        #expect(h2.tcp.connections.count == 1)
        sim.run(2 * S)
        #expect(h2.tcp.connections.isEmpty) // the 6th timeout, at 63 s
    }

    @Test func anEstablishedConnectionRetransmits15TimesBeforeTimingOut() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var cut = false
        tap.lose = { cut && tcpOf($0) != nil } // ARP still gets through after the cache expires
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 10_000_000)
        sim.run(10 * MS)
        cut = true
        sim.run(1206 * S)
        #expect(c.state == .established && c.failure == nil) // RTO 1, 2 … 64 s, then 120 s: the 16th timeout comes at ~1207 s
        #expect(segments(sim, "H1").filter { $0.time > 500 * MS }.count == 15) // Linux tcp_retries2
        sim.run(2 * S)
        #expect(c.state == .closed && c.failure == .timedOut)
    }

    @Test func retransmitsALostLastSegmentWhenTheRetransmissionTimerExpires() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var dropped = false
        tap.lose = { f in
            guard !dropped, tcpOf(f)?.dataLength == 80 else { return false }
            dropped = true
            return true
        }
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim.run(2 * S)
        let tail = segments(sim, "H1").filter { $0.seg.dataLength == 80 }
        #expect(tail.count == 2)
        let gap = tail[1].time - tail[0].time
        #expect(gap >= 1 * S && gap < 1 * S + 1 * MS) // RTO: microsecond RTTs, but never below 1 s (RFC 6298 (2.4))
        #expect(c.retransmissions == 1 && c.state == .timeWait && c.bytesAcked == 3000)
        #expect(c.rto == 2 * S) // backed off; Karn: the retransmission gives no RTT sample to bring it back
    }

    @Test func aServerThatForgotTheConnectionResetsIt() throws {
        let (sim, h1, h2, _) = try tapped()
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1_000_000)
        sim.run(1 * MS)
        #expect(h2.tcp.connections.map(\.state) == [.established])
        h2.reset() // a reboot: connections forgotten, the port still listening
        sim.run(1 * MS)
        #expect(segments(sim, "H2").map { label($0.seg) }.last == "R")
        #expect(c.state == .closed && c.failure == .reset)
    }

    @Test func startsWithThreeSegmentsAndGrowsBySlowStartThenCongestionAvoidance() throws {
        let (sim, h1, h2, _) = try tapped()
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 100_000)
        var initial = 0
        c.onChange = { [unowned c] in if c.state == .established { initial = c.cwnd } }
        sim.run(100 * MS)
        #expect(initial == 4380) // RFC 5681 IW: min(4 × MSS, max(2 × MSS, 4380 B))
        #expect(c.bytesAcked == 100_000 && c.ssthresh == 65_535)
        // 69 ACKs, one per segment: the first 42 add 1 MSS each (slow start) and take cwnd past ssthresh;
        // the other 27 add ⌊MSS² / cwnd⌋ = 32 B each (congestion avoidance). The FIN's ACK adds nothing.
        #expect(c.cwnd == 66_564)
    }

    @Test func threeDuplicateAcksTriggerAFastRetransmitAndRenoHalvesTheWindow() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var seen = 0
        var lost: UInt32?
        tap.lose = { f in
            guard lost == nil, let t = tcpOf(f), t.dataLength > 0 else { return false }
            seen += 1
            guard seen == 5 else { return false }
            lost = t.seq
            return true
        }
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 100_000)
        sim.run(100 * MS)
        let copies = segments(sim, "H1").filter { $0.seg.seq == lost && $0.seg.dataLength > 0 }
        #expect(copies.count == 2)
        #expect(copies[1].time - copies[0].time < 1 * MS) // long before the 1 s RTO
        let acks = sim.log.all.filter { e in
            e.kind == .rx && e.node == "H1" && e.time <= copies[1].time && e.frame.flatMap(tcpOf).map { $0.ack == lost && $0.dataLength == 0 } == true
        }
        #expect(acks.count >= 4) // the ACK of the segment before, then at least three duplicates
        #expect(c.retransmissions == 1 && c.rto == 1 * S) // no timeout happened
        #expect(c.ssthresh < 65_535 && c.ssthresh >= 2 * TCP_MSS) // the window was halved
        #expect(c.state == .timeWait && c.bytesAcked == 100_000)
    }

    @Test func aTimeoutCollapsesTheWindowToOneSegment() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var dropped = false
        tap.lose = { f in
            guard !dropped, tcpOf(f)?.dataLength == 80 else { return false }
            dropped = true
            return true
        }
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim.run(2 * S)
        #expect(c.ssthresh == 2 * TCP_MSS) // max(FlightSize / 2 = 81 / 2 B, 2 × MSS)
        #expect(c.cwnd == TCP_MSS + 80) // one segment, then slow start on the 80 bytes acknowledged
        #expect(c.retransmissions == 1)
    }

    @Test func aBulkTransferFillsA10MbLinkToTheTheoreticalGoodput() throws {
        let sim = Sim()
        let h1 = Host(sim: sim, id: "H1")
        let h2 = Host(sim: sim, id: "H2")
        _ = try Link(sim: sim, try h1.iface("eth0"), try h2.iface("eth0"), LinkOptions(bandwidthBps: 10e6))
        try h1.setIp("eth0", "10.0.0.1/24")
        try h2.setIp("eth0", "10.0.0.2/24")
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 2_000_000)
        sim.run(3 * S)
        let done = try #require(c.doneAt)
        let goodput = 2_000_000.0 * 8 / (Double(done - c.startedAt) / 1e9)
        // 1460 B of data per 1538 B on the wire (TCP 20 + IPv4 20 + Ethernet 14 + FCS 4 + preamble 8 + gap 12)
        let theory = 10e6 * 1460 / 1538
        #expect(abs(goodput - theory) / theory < 0.05)
    }
}
