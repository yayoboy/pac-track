import Foundation

/// Metrics interval (spec §5.6).
let SAMPLE_NS = 100 * MS
/// Points kept per flow and per cable: the last minute.
let METRICS_HISTORY = 600
/// UDP: like iperf3 waiting for the server's report, the summary comes this long after the last datagram.
private let UDP_REPORT_DELAY = 1 * S

struct TrafficResult: Sendable {
    var lines: [String] = []
    var done = false
    var samples: [FlowSample] = []
}

private func twoDecimals(_ v: Double) -> String {
    String(format: "%.2f", v)
}

private func keep(_ s: FlowSample, in samples: inout [FlowSample]) {
    samples.append(s)
    if samples.count > METRICS_HISTORY { samples.removeFirst() }
}

private func bitsPerSecond(_ bytes: Int) -> Double {
    Double(bytes) * 8 * Double(S) / Double(SAMPLE_NS)
}

private func resolutionError(_ target: String, _ r: Resolution) -> String {
    "iperf3: error - unable to resolve host \(target): " + (r == .nxdomain ? "Name or service not known" : "Temporary failure in name resolution")
}

/// iperf3-style TCP client: connects to the discard port, sends `bytes`, closes, and reports goodput and retransmissions.
/// The connection's timers keep it alive; it learns of every state change through `onChange` (captured weak).
final class TcpFlow {
    private(set) var result = TrafficResult()
    private let node: IpNode
    private let target: String
    private let bytes: Int
    private var conn: TcpConnection?
    private var connected = false
    private var lastAcked = 0

    init(node: IpNode, target: String, bytes: Int) throws {
        guard (1...1_000_000_000).contains(bytes) else { throw EngineError("Bytes must be between 1 and 1000000000") }
        self.node = node
        self.target = target
        self.bytes = bytes
        let literal = try literalIp(target)
        let name = literal == nil ? normalizeHostName(target) : nil
        guard literal != nil || name != nil else { throw EngineError("Invalid address or host name: \"\(target)\"") }
        if let literal {
            begin(literal)
            return
        }
        node.resolver.resolve(name!) { [weak self] r in self?.resolved(r) }
    }

    func stop() {
        guard !result.done else { return }
        conn?.abort()
        if !result.done {
            result.lines.append("iperf3: interrupt - the client has terminated")
            result.done = true
        }
    }

    /// After the end, one last point if bytes arrived since the previous one (a flow under 100 ms gets just that one).
    func sample(at time: Int) {
        guard let c = conn, !result.done || c.bytesAcked != lastAcked else { return }
        let acked = c.bytesAcked
        let loss = c.segmentsSent == 0 ? 0 : Double(c.retransmissions) / Double(c.segmentsSent) * 100
        keep(FlowSample(timeNs: time, bitsPerSecond: bitsPerSecond(acked - lastAcked), delayNs: c.srtt, jitterNs: nil, lossPct: loss),
             in: &result.samples)
        lastAcked = acked
    }

    private func resolved(_ r: Resolution) {
        guard !result.done else { return }
        if case .found(let addrs) = r, let first = addrs.first { return begin(first) }
        result.lines = [resolutionError(target, r)]
        result.done = true
    }

    private func begin(_ ip: UInt32) {
        result.lines = ["Connecting to host \(formatIp(ip)), port \(PORT_DISCARD)"]
        do {
            let c = try node.tcp.connect(to: ip, port: PORT_DISCARD, sending: bytes)
            c.onChange = { [weak self] in self?.update() }
            conn = c
        } catch {
            result.lines.append("iperf3: error - unable to connect to server: \(error)")
            result.done = true
        }
    }

    private func update() {
        guard let c = conn, !result.done else { return }
        if c.state == .established && !connected {
            connected = true
            result.lines.append("[  1] local \(formatIp(c.localIp)) port \(c.localPort) connected to \(formatIp(c.remoteIp)) port \(c.remotePort)")
        }
        guard c.state == .timeWait || c.state == .closed else { return }
        if let f = c.failure {
            result.lines.append(connected ? "iperf3: error - \(f.rawValue)" : "iperf3: error - unable to connect to server: \(f.rawValue)")
        } else if let done = c.doneAt {
            let seconds = Double(done - c.startedAt) / Double(S)
            result.lines.append("[  1]   0.00-\(twoDecimals(seconds)) sec  \(bytes) bytes  \(twoDecimals(Double(bytes) * 8 / seconds / 1e6)) Mbits/sec  \(c.retransmissions) retr")
            result.lines.append("iperf Done.")
        } else {
            result.lines.append("iperf3: interrupt - the client has terminated")
        }
        result.done = true
    }
}

/// iperf3-style UDP client: `bitsPerSecond` of 1470-byte datagrams to the discard port for `seconds`, evenly paced. The sink hands
/// every datagram back by flow id, so the flow measures what the receiver saw: one-way delay, RFC 3550 jitter and loss.
/// Pending timers keep it alive; it stores none (a retain cycle), so callbacks check `result.done`.
final class UdpFlow {
    private(set) var result = TrafficResult()
    private let node: IpNode
    private let target: String
    private let seconds: Int
    private let interval: Int
    private let count: Int
    private let flow: Int
    private let srcPort: UInt16
    private var dst: UInt32 = 0
    private var startedAt = 0
    private var sent = 0
    private var received = 0
    private var highest = -1
    private var transit: Int?
    private var jitter = 0.0
    private var lastBytes = 0
    private var delaySum = 0
    private var delayCount = 0

    init(node: IpNode, target: String, bitsPerSecond: Double, seconds: Int) throws {
        guard bitsPerSecond >= 1_000 && bitsPerSecond <= 1e9 else { throw EngineError("Bitrate must be between 1 kb/s and 1 Gb/s") }
        guard (1...3600).contains(seconds) else { throw EngineError("Duration must be between 1 and 3600 s") }
        self.node = node
        self.target = target
        self.seconds = seconds
        interval = Int((Double(TRAFFIC_DATAGRAM * 8) * Double(S) / bitsPerSecond).rounded())
        count = (seconds * S + interval - 1) / interval
        let literal = try literalIp(target)
        let name = literal == nil ? normalizeHostName(target) : nil
        guard literal != nil || name != nil else { throw EngineError("Invalid address or host name: \"\(target)\"") }
        flow = node.sim.nextId()
        srcPort = UInt16(32768 + node.sim.rng.int(28232))
        if let literal {
            begin(literal)
            return
        }
        node.resolver.resolve(name!) { [weak self] r in self?.resolved(r) }
    }

    func stop() {
        guard !result.done else { return }
        guard sent > 0 else {
            result.lines.append("iperf3: interrupt - the client has terminated")
            return finish()
        }
        report()
    }

    /// After the end, one last point if datagrams arrived since the previous one.
    func sample(at time: Int) {
        let bytes = received * TRAFFIC_DATAGRAM
        guard sent > 0, !result.done || bytes != lastBytes else { return }
        let loss = highest < 0 ? 0 : Double(highest + 1 - received) / Double(highest + 1) * 100
        keep(FlowSample(timeNs: time, bitsPerSecond: bitsPerSecond(bytes - lastBytes), delayNs: delayCount == 0 ? nil : delaySum / delayCount,
                        jitterNs: Int(jitter.rounded()), lossPct: loss), in: &result.samples)
        lastBytes = bytes
        delaySum = 0
        delayCount = 0
    }

    private func resolved(_ r: Resolution) {
        guard !result.done else { return }
        if case .found(let addrs) = r, let first = addrs.first { return begin(first) }
        result.lines = [resolutionError(target, r)]
        result.done = true
    }

    private func begin(_ ip: UInt32) {
        dst = ip
        startedAt = node.sim.now
        result.lines = ["Connecting to host \(formatIp(ip)), port \(PORT_DISCARD)"]
        guard let src = node.sourceFor(ip) else {
            result.lines.append("iperf3: error - unable to connect to server: Network is unreachable")
            return finish()
        }
        result.lines.append("[  1] local \(formatIp(src)) port \(srcPort) connected to \(formatIp(ip)) port \(PORT_DISCARD)")
        node.sim.flows[flow] = { [weak self] d in self?.arrived(d) }
        send(0)
        node.sim.sched.after(seconds * S + UDP_REPORT_DELAY) { [self] in report() }
    }

    private func send(_ seq: Int) {
        guard !result.done else { return }
        node.sendUdp(dst, srcPort: srcPort, dstPort: PORT_DISCARD, payload: .traffic(TrafficData(flow: flow, seq: seq, sentAt: node.sim.now)))
        sent += 1
        if seq + 1 < count { node.sim.sched.after(interval) { [self] in send(seq + 1) } }
    }

    private func arrived(_ d: TrafficData) {
        guard !result.done else { return }
        let t = node.sim.now - d.sentAt
        if let previous = transit { jitter += (Double(abs(t - previous)) - jitter) / 16 } // RFC 3550 §6.4.1
        transit = t
        received += 1
        highest = max(highest, d.seq)
        delaySum += t
        delayCount += 1
    }

    /// iperf3's closing line: what the receiver got over the configured time (or until stopped).
    private func report() {
        guard !result.done else { return }
        let elapsed = Double(min(node.sim.now - startedAt, seconds * S)) / Double(S)
        let bytes = received * TRAFFIC_DATAGRAM
        let lost = sent - received
        let pct = Int((Double(lost) / Double(sent) * 100).rounded())
        let rate = elapsed == 0 ? 0 : Double(bytes) * 8 / elapsed / 1e6
        result.lines.append("[  1]   0.00-\(twoDecimals(elapsed)) sec  \(bytes) bytes  \(twoDecimals(rate)) Mbits/sec  "
            + "\(formatMs(Int(jitter.rounded()))) ms  \(lost)/\(sent) (\(pct)%)")
        result.lines.append("iperf Done.")
        finish()
    }

    private func finish() {
        result.done = true
        node.sim.flows[flow] = nil
    }
}
