struct PingOptions: Sendable {
    var count = 4
    var intervalNs = 1 * S
    /// How long to wait after the last request before giving up.
    var timeoutNs = 10 * S
    var size = 56
    var ttl: Int? = nil
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
    private let dst: UInt32
    private let opts: PingOptions
    private let id: UInt16
    private var sentAt: [Int: Int] = [:]
    private var unlisten: () -> Void = {}

    init(node: IpNode, target: String, options: PingOptions = PingOptions()) throws {
        let o = options
        // Upper bounds keep timer arithmetic far from overflow and the timer list small.
        guard (1...10_000).contains(o.count), (1...3600 * S).contains(o.intervalNs), (1...3600 * S).contains(o.timeoutNs),
              (0...65507).contains(o.size),
              o.ttl.map({ (1...255).contains($0) }) ?? true else {
            throw EngineError("Invalid ping option: \(options)")
        }
        self.node = node
        self.target = target
        opts = o
        dst = try parseIp(target)
        id = UInt16(node.sim.rng.int(0x10000))
        result.lines = ["PING \(target) (\(target)) \(o.size)(\(o.size + 28)) bytes of data."]
        unlisten = node.onIcmp { [weak self] p, m in self?.onIcmp(p, m) }
        for seq in 1...o.count {
            node.sim.sched.after((seq - 1) * o.intervalNs) { [self] in send(seq) }
        }
        node.sim.sched.after((o.count - 1) * o.intervalNs + o.timeoutNs) { [self] in finish(stats: true) }
    }

    func stop() {
        finish(stats: true)
    }

    private func send(_ seq: Int) {
        guard !result.done else { return }
        let payload = L4.icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: id, seq: UInt16(truncatingIfNeeded: seq),
                                       data: [UInt8](repeating: 0, count: opts.size)))
        sentAt[seq] = node.sim.now
        guard node.sendPacket(dst, payload, ttl: opts.ttl.map { UInt8($0) }) else {
            sentAt[seq] = nil
            result.lines.append("ping: connect: Network is unreachable")
            return finish(stats: false)
        }
        result.transmitted += 1
    }

    private func onIcmp(_ p: Ipv4Packet, _ m: IcmpMessage) {
        if m.type == ICMP_ECHO_REPLY {
            let seq = Int(m.seq)
            guard m.id == id, let at = sentAt.removeValue(forKey: seq) else { return }
            let rtt = node.sim.now - at
            result.received += 1
            result.replies.append(PingReply(seq: seq, from: formatIp(p.src), ttl: Int(p.ttl), rttNs: rtt))
            result.lines.append("\(m.data.count + 8) bytes from \(formatIp(p.src)): icmp_seq=\(seq) ttl=\(p.ttl) time=\(formatMs(rtt)) ms")
            return settleIfComplete()
        }
        guard m.type == ICMP_DEST_UNREACH || m.type == ICMP_TIME_EXCEEDED else { return }
        // Quoted datagram: our IPv4 header (20 B) + first 8 B of our echo request.
        let q = m.data
        guard q.count >= 28, q[20] == ICMP_ECHO_REQUEST, UInt16(q[24]) << 8 | UInt16(q[25]) == id else { return }
        let seq = Int(UInt16(q[26]) << 8 | UInt16(q[27]))
        sentAt[seq] = nil
        result.errors.append(PingError(seq: seq, from: formatIp(p.src), type: Int(m.type), code: Int(m.code)))
        let text = ERROR_TEXT["\(m.type)/\(m.code)"] ?? "ICMP type \(m.type) code \(m.code)"
        result.lines.append("From \(formatIp(p.src)) icmp_seq=\(seq) \(text)")
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
