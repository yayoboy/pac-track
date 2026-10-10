/// iputils options (spec §5.6): -c count, -i interval, -W timeout, -s size, -t ttl (nil: the node's default).
public struct PingOptions: Equatable, Sendable {
    public var count: Int
    public var intervalNs: Int
    /// How long to wait after the last request before giving up.
    public var timeoutNs: Int
    public var size: Int
    public var ttl: Int?

    public init(count: Int = 4, intervalNs: Int = 1_000_000_000, timeoutNs: Int = 10_000_000_000, size: Int = 56, ttl: Int? = nil) {
        self.count = count
        self.intervalNs = intervalNs
        self.timeoutNs = timeoutNs
        self.size = size
        self.ttl = ttl
    }
}

struct PingReply: Equatable, Sendable {
    let seq: Int
    let from: String
    let ttl: Int
    let rttNs: Int
}

struct PingError: Equatable, Sendable {
    let seq: Int
    let from: String
    let type: Int
    let code: Int
}

struct PingResult: Sendable {
    var transmitted = 0
    var received = 0
    var replies: [PingReply] = []
    var errors: [PingError] = []
    var lines: [String] = []
    var done = false
}

private let ERROR_TEXT: [String: String] = [
    "3/0": "Destination Net Unreachable",
    "3/1": "Destination Host Unreachable",
    "3/3": "Destination Port Unreachable",
    "3/4": "Frag needed and DF set",
    "11/0": "Time to live exceeded",
]

/// iputils' wording for ICMPv6 errors (spec M9 §7).
private func errorText6(_ m: IcmpMessage) -> String {
    switch (m.type, m.code) {
    case (ICMP6_DEST_UNREACH, UNREACH6_NO_ROUTE): "Destination unreachable: No route"
    case (ICMP6_DEST_UNREACH, UNREACH6_ADDRESS): "Destination unreachable: Address unreachable"
    case (ICMP6_DEST_UNREACH, UNREACH6_PORT): "Destination unreachable: Port unreachable"
    case (ICMP6_PACKET_TOO_BIG, _): "Packet too big: mtu=\(Int(m.id) << 16 | Int(m.seq))"
    case (ICMP6_TIME_EXCEEDED, 0): "Time exceeded: Hop limit"
    default: "ICMPv6 type \(m.type) code \(m.code)"
    }
}

/// An IPv6 destination for ping, traceroute or the traffic generator (spec M9 §7): nil without a ":". Link-local and multicast
/// destinations are refused, with or without a zone ("fe80::1%eth0"), since Linux needs the zone and Pac-Track has none (§2);
/// a zone on any other address is not an address.
func ipv6Target(_ s: String, tool: String) throws -> UInt128? {
    guard s.contains(":") else { return nil }
    let a = try parseIp6(String(s.prefix { $0 != "%" }))
    if isLinkLocal6(a) || isMulticast6(a) { throw EngineError("\(tool) to link-local or multicast addresses is not supported") }
    if s.contains("%") { throw EngineError("Invalid IPv6 address: \"\(s)\"") }
    return a
}

/// Milliseconds with 3 decimals, rounding half up like JavaScript's toFixed (printf would round half to even).
func formatMs(_ ns: Int) -> String {
    let us = (ns + 500) / 1000
    let fraction = String(us % 1000)
    return "\(us / 1000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
}

/// Linux-style ping. Output lines mimic iputils.
/// Pending timers keep it alive until it finishes; it stores no timers itself (that would be a retain cycle),
/// so callbacks check `result.done` instead of being cancelled.
final class Ping {
    private(set) var result = PingResult()
    private let node: IpNode
    private let target: String
    private var dst: UInt32 = 0
    /// Set for an IPv6 target (spec M9 §7).
    private var dst6: UInt128?
    private let opts: PingOptions
    private let id: UInt16
    private var sentAt: [Int: Int] = [:]
    private var unlisten: () -> Void = {}

    init(node: IpNode, target: String, options: PingOptions = PingOptions()) throws {
        let o = options
        // Upper bounds keep timer arithmetic far from overflow and the timer list small.
        let problem: String? =
            !(1...10_000).contains(o.count) ? "count must be between 1 and 10000"
            : !(1...3600 * S).contains(o.intervalNs) ? "interval must be above 0 and at most 3600 s"
            : !(1...3600 * S).contains(o.timeoutNs) ? "timeout must be above 0 and at most 3600 s"
            : !(0...65507).contains(o.size) ? "size must be between 0 and 65507 bytes"
            : o.ttl.map({ !(1...255).contains($0) }) ?? false ? "TTL must be between 1 and 255"
            : nil
        if let problem { throw EngineError("Invalid ping option: \(problem)") }
        self.node = node
        self.target = target
        opts = o
        let v6 = try ipv6Target(target, tool: "Ping")
        let literal = try v6 == nil ? literalIp(target) : nil
        let name = v6 == nil && literal == nil ? normalizeHostName(target) : nil
        guard v6 != nil || literal != nil || name != nil else { throw EngineError("Invalid address or host name: \"\(target)\"") }
        id = UInt16(node.sim.rng.int(0x10000))
        if let v6 {
            begin6(v6)
            return
        }
        if let literal {
            begin(literal)
            return
        }
        // The runtime's app list keeps this ping alive while the name resolves.
        node.resolver.resolve(name!) { [weak self] r in self?.resolved(r) }
    }

    private func begin(_ ip: UInt32) {
        dst = ip
        result.lines = ["PING \(target) (\(formatIp(ip))) \(opts.size)(\(opts.size + 28)) bytes of data."]
        unlisten = node.onIcmp { [weak self] p, m in self?.onIcmp(from: formatIp(p.src), ttl: Int(p.ttl), m) }
        schedule()
    }

    private func begin6(_ ip: UInt128) {
        dst6 = ip
        result.lines = ["PING \(target)(\(formatIp6(ip))) \(opts.size) data bytes"]
        unlisten = node.v6.onIcmp { [weak self] p, m in self?.onIcmp(from: formatIp6(p.src), ttl: Int(p.hopLimit), m) }
        schedule()
    }

    private func schedule() {
        for seq in 1...opts.count {
            node.sim.sched.after((seq - 1) * opts.intervalNs) { [self] in send(seq) }
        }
        node.sim.sched.after((opts.count - 1) * opts.intervalNs + opts.timeoutNs) { [self] in finish(stats: true) }
    }

    private func resolved(_ r: Resolution) {
        guard !result.done else { return }
        if case .found(let addrs) = r, let first = addrs.first { return begin(first) }
        result.lines = ["ping: \(target): " + (r == .nxdomain ? "Name or service not known" : "Temporary failure in name resolution")]
        finish(stats: false)
    }

    func stop() {
        finish(stats: true)
    }

    private func send(_ seq: Int) {
        guard !result.done else { return }
        let data = [UInt8](repeating: 0, count: opts.size)
        let s = UInt16(truncatingIfNeeded: seq)
        let ttl = opts.ttl.map { UInt8($0) }
        sentAt[seq] = node.sim.now
        let sent = if let dst6 {
            node.v6.send(dst6, .icmp(IcmpMessage(type: ICMP6_ECHO_REQUEST, code: 0, checksum: 0, id: id, seq: s, data: data)), hopLimit: ttl)
        } else {
            node.sendPacket(dst, .icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: id, seq: s, data: data)), ttl: ttl)
        }
        guard sent else {
            sentAt[seq] = nil
            result.lines.append("ping: connect: Network is unreachable")
            return finish(stats: false)
        }
        result.transmitted += 1
    }

    private func onIcmp(from: String, ttl: Int, _ m: IcmpMessage) {
        let v6 = dst6 != nil
        if m.type == (v6 ? ICMP6_ECHO_REPLY : ICMP_ECHO_REPLY) {
            let seq = Int(m.seq)
            guard m.id == id, let at = sentAt.removeValue(forKey: seq) else { return }
            let rtt = node.sim.now - at
            result.received += 1
            result.replies.append(PingReply(seq: seq, from: from, ttl: ttl, rttNs: rtt))
            result.lines.append("\(m.data.count + 8) bytes from \(from): icmp_seq=\(seq) ttl=\(ttl) time=\(formatMs(rtt)) ms")
            return settleIfComplete()
        }
        guard v6 ? m.type < 128 : m.type == ICMP_DEST_UNREACH || m.type == ICMP_TIME_EXCEEDED else { return }
        // Quoted datagram: our IP header (IPv4 20 B, IPv6 40 B) + the first 8 B of our echo request.
        let q = m.data
        let at = v6 ? 40 : 20
        guard q.count >= at + 8, q[at] == (v6 ? ICMP6_ECHO_REQUEST : ICMP_ECHO_REQUEST), UInt16(q[at + 4]) << 8 | UInt16(q[at + 5]) == id else { return }
        let seq = Int(UInt16(q[at + 6]) << 8 | UInt16(q[at + 7]))
        sentAt[seq] = nil
        result.errors.append(PingError(seq: seq, from: from, type: Int(m.type), code: Int(m.code)))
        let text = v6 ? errorText6(m) : ERROR_TEXT["\(m.type)/\(m.code)"] ?? "ICMP type \(m.type) code \(m.code)"
        result.lines.append("From \(from) icmp_seq=\(seq) \(text)")
        settleIfComplete()
    }

    private func settleIfComplete() {
        if result.transmitted == opts.count && sentAt.isEmpty { finish(stats: true) }
    }

    private func finish(stats: Bool) {
        guard !result.done else { return }
        result.done = true
        unlisten()
        guard stats else { return }
        let lost = result.transmitted - result.received
        let loss = result.transmitted == 0 ? 0 : Int((Double(lost) / Double(result.transmitted) * 100).rounded())
        let errors = result.errors.isEmpty ? "" : "+\(result.errors.count) errors, "
        result.lines.append("--- \(target) ping statistics ---")
        result.lines.append("\(result.transmitted) packets transmitted, \(result.received) received, \(errors)\(loss)% packet loss")
    }
}
