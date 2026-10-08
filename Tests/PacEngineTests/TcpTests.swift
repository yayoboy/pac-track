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
}
