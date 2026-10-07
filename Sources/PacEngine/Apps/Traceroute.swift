struct TracerouteOptions: Sendable {
    var maxHops = 30
    var probes = 3
    var waitNs = 5 * S
    var firstPort = 33434
}

struct TraceProbe: Equatable, Sendable {
    var from: String?
    var rttNs: Int?
    var note: String?
}

struct TraceHop: Equatable, Sendable {
    let ttl: Int
    var probes: [TraceProbe]
}

struct TracerouteResult: Sendable {
    var hops: [TraceHop] = []
    var reached = false
    var done = false
    var lines: [String] = []
}

private let NOTES: [UInt8: String] = [0: "!N", 1: "!H", 4: "!F"]

private func formatHop(_ hop: TraceHop) -> String {
    var line = (hop.ttl < 10 ? " " : "") + "\(hop.ttl) "
    var last: String?
    for p in hop.probes {
        guard let from = p.from, let rtt = p.rttNs else {
            line += " *"
            continue
        }
        if from != last {
            line += " \(from) (\(from))"
            last = from
        }
        line += "  \(formatMs(rtt)) ms" + (p.note.map { " \($0)" } ?? "")
    }
    return line
}

private final class InFlight {
    let hopIndex: Int
    var sent: [UInt16: (index: Int, at: Int)] = [:]
    var pending: Int

    init(hopIndex: Int, pending: Int) {
        self.hopIndex = hopIndex
        self.pending = pending
    }
}

/// Linux-style UDP traceroute: `probes` probes per TTL, one hop at a time.
/// Pending timers keep it alive; it stores none itself (retain cycle), so a hop timeout checks it is still current.
final class Traceroute {
    private(set) var result = TracerouteResult()
    private let node: IpNode
    private let dst: UInt32
    private let opts: TracerouteOptions
    private let srcPort: UInt16
    private var port: Int
    private var current: InFlight?
    private var unlisten: () -> Void = {}

    init(node: IpNode, target: String, options: TracerouteOptions = TracerouteOptions()) throws {
        let o = options
        guard (1...255).contains(o.maxHops), (1...10).contains(o.probes), (1...60 * S).contains(o.waitNs),
              (1...0xFFFF).contains(o.firstPort), o.firstPort + o.maxHops * o.probes <= 0x10000 else {
            throw EngineError("Invalid traceroute option: \(options)")
        }
        self.node = node
        opts = o
        dst = try parseIp(target)
        srcPort = UInt16(33000 + node.sim.rng.int(10000))
        port = o.firstPort
        result.lines = ["traceroute to \(target) (\(target)), \(o.maxHops) hops max, 60 byte packets"]
        unlisten = node.onIcmp { [weak self] p, m in self?.onIcmp(p, m) }
        node.sim.sched.after(0) { [self] in sendHop(1) }
    }

    func stop() {
        finish()
    }

    private func sendHop(_ ttl: Int) {
        guard !result.done else { return }
        result.hops.append(TraceHop(ttl: ttl, probes: Array(repeating: TraceProbe(), count: opts.probes)))
        let flight = InFlight(hopIndex: result.hops.count - 1, pending: opts.probes)
        current = flight
        for i in 0..<opts.probes {
            let dport = UInt16(port)
            port += 1
            flight.sent[dport] = (i, node.sim.now)
            guard node.sendUdp(dst, srcPort: srcPort, dstPort: dport, data: [UInt8](repeating: 0, count: 32), ttl: UInt8(ttl)) else {
                result.lines.append("connect: Network is unreachable")
                return finish()
            }
        }
        node.sim.sched.after(opts.waitNs) { [self] in
            if current === flight { closeHop() }
        }
    }

    private func closeHop() {
        guard let flight = current else { return }
        current = nil
        let hop = result.hops[flight.hopIndex]
        result.lines.append(formatHop(hop))
        if result.reached || hop.ttl >= opts.maxHops {
            finish()
        } else {
            sendHop(hop.ttl + 1)
        }
    }

    private func onIcmp(_ p: Ipv4Packet, _ m: IcmpMessage) {
        guard let flight = current, m.type == ICMP_TIME_EXCEEDED || m.type == ICMP_DEST_UNREACH else { return }
        // Quoted datagram: original IPv4 header (20 B) + UDP header (8 B). Only our own probes count.
        let q = m.data
        guard q.count >= 28, q[9] == IPPROTO_UDP else { return }
        let quotedDst = UInt32(q[16]) << 24 | UInt32(q[17]) << 16 | UInt32(q[18]) << 8 | UInt32(q[19])
        let quotedSrcPort = UInt16(q[20]) << 8 | UInt16(q[21])
        guard quotedDst == dst, quotedSrcPort == srcPort else { return }
        let dport = UInt16(q[22]) << 8 | UInt16(q[23])
        guard let probe = flight.sent.removeValue(forKey: dport) else { return }
        let note = m.type == ICMP_DEST_UNREACH && m.code != UNREACH_PORT ? NOTES[m.code] ?? "!<\(m.code)>" : nil
        result.hops[flight.hopIndex].probes[probe.index] = TraceProbe(from: formatIp(p.src), rttNs: node.sim.now - probe.at, note: note)
        if m.type == ICMP_DEST_UNREACH { result.reached = true }
        flight.pending -= 1
        if flight.pending == 0 { closeHop() }
    }

    private func finish() {
        guard !result.done else { return }
        result.done = true
        current = nil
        unlisten()
    }
}
