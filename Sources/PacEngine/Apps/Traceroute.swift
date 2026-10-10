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
/// traceroute's marks for ICMPv6 destination unreachable: no route, administratively prohibited, address unreachable.
private let NOTES6: [UInt8: String] = [0: "!N", 1: "!X", 3: "!H"]

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
    private var dst: UInt32 = 0
    /// Set for an IPv6 target (spec M9 §7).
    private var dst6: UInt128?
    private let target: String
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
        self.target = target
        opts = o
        let v6 = try ipv6Target(target, tool: "Traceroute")
        let literal = try v6 == nil ? literalIp(target) : nil
        let name = v6 == nil && literal == nil ? normalizeHostName(target) : nil
        guard v6 != nil || literal != nil || name != nil else { throw EngineError("Invalid address or host name: \"\(target)\"") }
        srcPort = UInt16(33000 + node.sim.rng.int(10000))
        port = o.firstPort
        if let v6 {
            begin6(v6)
            return
        }
        if let literal {
            begin(literal)
            return
        }
        node.resolver.resolve(name!) { [weak self] r in self?.resolved(r) }
    }

    private func begin(_ ip: UInt32) {
        dst = ip
        result.lines = ["traceroute to \(target) (\(formatIp(ip))), \(opts.maxHops) hops max, 60 byte packets"]
        unlisten = node.onIcmp { [weak self] p, m in self?.onIcmp(from: formatIp(p.src), m) }
        node.sim.sched.after(0) { [self] in sendHop(1) }
    }

    /// Linux traceroute over IPv6: 40 B header + 8 B UDP + 32 B of data.
    private func begin6(_ ip: UInt128) {
        dst6 = ip
        result.lines = ["traceroute to \(target) (\(formatIp6(ip))), \(opts.maxHops) hops max, 80 byte packets"]
        unlisten = node.v6.onIcmp { [weak self] p, m in self?.onIcmp(from: formatIp6(p.src), m) }
        node.sim.sched.after(0) { [self] in sendHop(1) }
    }

    private func resolved(_ r: Resolution) {
        guard !result.done else { return }
        if case .found(let addrs) = r, let first = addrs.first { return begin(first) }
        result.lines = ["\(target): " + (r == .nxdomain ? "Name or service not known" : "Temporary failure in name resolution"),
                        "Cannot handle \"host\" cmdline arg `\(target)' on position 1 (argc 1)"]
        finish()
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
            let data = [UInt8](repeating: 0, count: 32)
            let sent = if let dst6 {
                node.v6.send(dst6, .udp(makeUdp(srcPort: srcPort, dstPort: dport, data: data)), hopLimit: UInt8(ttl))
            } else {
                node.sendUdp(dst, srcPort: srcPort, dstPort: dport, data: data, ttl: UInt8(ttl))
            }
            guard sent else {
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

    private func onIcmp(from: String, _ m: IcmpMessage) {
        let v6 = dst6 != nil
        let exceeded = v6 ? ICMP6_TIME_EXCEEDED : ICMP_TIME_EXCEEDED
        let unreach = v6 ? ICMP6_DEST_UNREACH : ICMP_DEST_UNREACH
        guard let flight = current, m.type == exceeded || m.type == unreach else { return }
        // Quoted datagram: the original IP header (IPv4 20 B, IPv6 40 B) + UDP header (8 B). Only our own probes count.
        let q = m.data
        let at = v6 ? 40 : 20
        guard q.count >= at + 8, q[v6 ? 6 : 9] == IPPROTO_UDP else { return }
        let ours: Bool
        if let dst6 {
            ours = Array(q[24..<40]) == bytes16(dst6)
        } else {
            let quotedDst = UInt32(q[16]) << 24 | UInt32(q[17]) << 16 | UInt32(q[18]) << 8 | UInt32(q[19])
            ours = quotedDst == dst
        }
        let quotedSrcPort = UInt16(q[at]) << 8 | UInt16(q[at + 1])
        guard ours, quotedSrcPort == srcPort else { return }
        let dport = UInt16(q[at + 2]) << 8 | UInt16(q[at + 3])
        guard let probe = flight.sent.removeValue(forKey: dport) else { return }
        let portUnreachable = v6 ? UNREACH6_PORT : UNREACH_PORT
        let note = m.type == unreach && m.code != portUnreachable ? (v6 ? NOTES6 : NOTES)[m.code] ?? "!<\(m.code)>" : nil
        result.hops[flight.hopIndex].probes[probe.index] = TraceProbe(from: from, rttNs: node.sim.now - probe.at, note: note)
        if m.type == unreach { result.reached = true }
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
