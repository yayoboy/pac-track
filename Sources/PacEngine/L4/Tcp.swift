let TCP_MSS = 1460
/// RFC 879: the MSS to assume when a SYN carries no option.
private let TCP_DEFAULT_MSS = 536
/// Receive buffer and advertised window: 64 KB, no window scaling.
let TCP_WINDOW = 65_535
/// RFC 6298 (2.1), (2.4): 1 s before the first RTT sample and never less.
let TCP_MIN_RTO = 1 * S
/// RFC 6298 (2.5) allows any cap of at least 60 s; Linux TCP_RTO_MAX.
let TCP_MAX_RTO = 120 * S
/// Retransmissions of one segment before giving up (Linux tcp_syn_retries: the 7th SYN goes out at 63 s, failure at 127 s).
let TCP_MAX_RETRIES = 6
/// Linux TCP_TIMEWAIT_LEN.
let TCP_TIME_WAIT = 60 * S

/// RFC 793 states, named as netstat shows them. CLOSE_WAIT never lasts: the sink closes as soon as it reads the FIN.
enum TcpState: String, Sendable {
    case synSent = "SYN_SENT"
    case synReceived = "SYN_RECV"
    case established = "ESTABLISHED"
    case finWait1 = "FIN_WAIT1"
    case finWait2 = "FIN_WAIT2"
    case lastAck = "LAST_ACK"
    case timeWait = "TIME_WAIT"
    case closed = "CLOSED"
}

enum TcpFailure: String, Sendable {
    case refused = "Connection refused"
    case timedOut = "Connection timed out"
    case reset = "Connection reset by peer"
}

/// One end of a connection. The active end (the generator) sends `dataLength` bytes and closes; the passive end (the sink)
/// discards what arrives and closes when the peer does. Sequence numbers are offsets from each ISN: 0 is the SYN, data starts at 1.
// ponytail: one-way bulk data, no delayed ACK, SACK, timestamps, window scaling, persist or keepalive timers
final class TcpConnection {
    unowned let tcp: Tcp
    let localIp: UInt32
    let localPort: UInt16
    let remoteIp: UInt32
    let remotePort: UInt16
    let startedAt: Int
    private(set) var state: TcpState {
        didSet { if state != oldValue { onChange?() } }
    }
    private(set) var failure: TcpFailure?
    /// When the last data byte was acknowledged.
    private(set) var doneAt: Int?
    /// Called after every state change; the app reads the connection then.
    var onChange: (() -> Void)?
    /// Data segments put on the wire, retransmissions included.
    private(set) var segmentsSent = 0
    private(set) var retransmissions = 0

    // Send side.
    private let iss: UInt32
    private let dataLength: Int
    private var finQueued: Bool
    /// Oldest unacknowledged offset, next offset to send, highest offset ever sent.
    private var una = 0
    private var nxt = 0
    private var sentMax = 0
    private var mss = TCP_MSS
    private var peerWindow = TCP_WINDOW

    // RFC 6298 retransmission timer.
    private(set) var srtt: Int?
    private var rttvar = 0
    private(set) var rto = TCP_MIN_RTO
    /// The one segment being timed: its end offset and send time.
    private var timed: (end: Int, at: Int)?
    private var retries = 0
    private var synRetransmitted = false
    private var deadline: Int?
    private var armedAt: Int?
    private var timerGen = 0

    // RFC 5681 congestion control (Reno).
    private(set) var cwnd = TCP_MSS
    private(set) var ssthresh = TCP_WINDOW
    private var dupAcks = 0
    private var recovering = false

    // Receive side.
    private var irs: UInt32 = 0
    private var rcvNxt = 0
    private var outOfOrder: [Range<Int>] = []
    /// Where the peer's FIN sits once seen (it may arrive before the data in front of it).
    private var peerFin: Int?

    init(tcp: Tcp, local: UInt32, localPort: UInt16, remote: UInt32, remotePort: UInt16, sending bytes: Int, state: TcpState) {
        self.tcp = tcp
        localIp = local
        self.localPort = localPort
        remoteIp = remote
        self.remotePort = remotePort
        startedAt = tcp.node.sim.now
        self.state = state
        dataLength = bytes
        // The generator closes as soon as its data is out; the sink when the peer does.
        finQueued = state == .synSent
        iss = tcp.node.sim.rng.uint32()
    }

    var bytesAcked: Int { min(max(una - 1, 0), dataLength) }

    private var now: Int { tcp.node.sim.now }
    /// Offset of the FIN: just past the data.
    private var dataEnd: Int { dataLength + 1 }

    /// Active open.
    func open() {
        output()
    }

    /// Passive open: answers a SYN that reached a listening port.
    func accept(_ syn: TcpSegment) {
        irs = syn.seq
        rcvNxt = 1
        learn(syn)
        output()
    }

    func receive(_ s: TcpSegment) {
        guard state != .closed else { return }
        // ponytail: any RST is believed (no RFC 5961 sequence check)
        if s.flags.contains(.rst) { return fail(state == .synSent ? .refused : .reset) }
        if state == .synSent {
            // ponytail: simultaneous open (a bare SYN while in SYN_SENT) is not modelled
            guard s.flags.contains([.syn, .ack]), ours(s.ack) == 1 else { return }
            irs = s.seq
            rcvNxt = 1
            learn(s)
            acknowledged(1, window: s.window)
            established()
            sendAck()
            return output()
        }
        // A repeated SYN-ACK (our ACK was lost) or a stray SYN: acknowledge it, nothing else.
        if s.flags.contains(.syn) { return sendAck() }
        guard s.flags.contains(.ack) else { return }
        let a = ours(s.ack)
        if a > una && a <= sentMax {
            acknowledged(a, window: s.window)
        } else if a == una && s.dataLength == 0 && !s.flags.contains(.fin) && sentMax > una && Int(s.window) == peerWindow {
            duplicateAck() // RFC 5681 §2: same ACK, no data, same window, data outstanding
        }
        guard state != .closed else { return }
        if s.dataLength > 0 || s.flags.contains(.fin) { arrived(s) }
        output() // the ACK may have opened the window
    }

    /// Kills the connection like SO_LINGER 0: one RST to the peer, then gone.
    func abort() {
        guard state != .closed else { return }
        if state != .synSent { send([.rst, .ack], at: nxt, length: 0) }
        close()
    }

    /// Power cycle: the connection vanishes without a word (its timers find it closed).
    func abandon() {
        deadline = nil
        state = .closed
    }

    private func learn(_ syn: TcpSegment) {
        mss = min(TCP_MSS, Int(syn.mss ?? UInt16(TCP_DEFAULT_MSS)))
        peerWindow = Int(syn.window)
    }

    /// Offset in our sequence space of an acknowledgment number.
    private func ours(_ ack: UInt32) -> Int {
        Int(ack &- iss)
    }

    /// A new cumulative ACK: everything before offset `a` arrived.
    private func acknowledged(_ a: Int, window: UInt16) {
        let newData = min(a, dataEnd) - min(una, dataEnd)
        una = a
        nxt = max(nxt, una)
        peerWindow = Int(window)
        retries = 0
        if let t = timed, a >= t.end {
            measure(now - t.at)
            timed = nil
        }
        if newData > 0 { grow(newData) }
        dupAcks = 0
        // RFC 6298 (5.2), (5.3): stop when everything is acknowledged, otherwise restart.
        setTimer(una == sentMax ? nil : now + rto)
        if doneAt == nil, dataLength > 0, una >= dataEnd { doneAt = now }
        switch state {
        case .synReceived: established()
        case .finWait1 where finQueued && una > dataEnd: state = .finWait2
        case .lastAck where una > dataEnd: close()
        default: break
        }
    }

    /// RFC 5681 §3.1: slow start below ssthresh, congestion avoidance above; §3.2 (6): Reno deflates on the first new ACK.
    private func grow(_ acked: Int) {
        if recovering {
            cwnd = ssthresh
            recovering = false
        } else if cwnd < ssthresh {
            cwnd += min(acked, mss)
        } else {
            cwnd += max(1, mss * mss / cwnd)
        }
    }

    /// RFC 5681 §3.2: the third duplicate retransmits the missing segment and enters fast recovery; later ones inflate the window.
    private func duplicateAck() {
        dupAcks += 1
        if dupAcks == 3 && !recovering && una < dataEnd {
            ssthresh = max((sentMax - una) / 2, 2 * mss)
            transmit([.ack], at: una, length: min(mss, dataEnd - una))
            cwnd = ssthresh + 3 * mss
            recovering = true
        } else if recovering {
            cwnd += mss
            output()
        }
    }

    /// RFC 6298 (2.2), (2.3).
    private func measure(_ r: Int) {
        if let s = srtt {
            rttvar = (3 * rttvar + abs(s - r)) / 4
            srtt = (7 * s + r) / 8
        } else {
            srtt = r
            rttvar = r / 2
        }
        // ponytail: clock granularity G left out: the 1 s floor dwarfs it
        rto = min(max(srtt! + 4 * rttvar, TCP_MIN_RTO), TCP_MAX_RTO)
    }

    private func established() {
        // RFC 6298 (5.7): a SYN that timed out leaves at least a 3 s RTO.
        if synRetransmitted { rto = max(rto, 3 * S) }
        // RFC 5681 §3.1: initial window min(4 × SMSS, max(2 × SMSS, 4380 B)); one segment if the SYN had to be repeated.
        cwnd = synRetransmitted ? mss : min(4 * mss, max(2 * mss, 4380))
        state = .established
    }

    /// Data or FIN from the peer: new bytes inside the window are kept (out-of-order pieces wait for the gap), then ACKed at once.
    private func arrived(_ s: TcpSegment) {
        let start = Int(s.seq &- irs)
        let end = start + s.dataLength
        if s.flags.contains(.fin) { peerFin = end }
        if s.dataLength > 0, end > rcvNxt, start < rcvNxt + TCP_WINDOW {
            outOfOrder.append(max(start, rcvNxt)..<end)
            outOfOrder.sort { $0.lowerBound < $1.lowerBound }
            while let first = outOfOrder.first, first.lowerBound <= rcvNxt {
                rcvNxt = max(rcvNxt, first.upperBound)
                outOfOrder.removeFirst()
            }
        }
        guard rcvNxt == peerFin else { return sendAck() }
        rcvNxt += 1
        switch state {
        case .established:
            // The sink reads end-of-file and closes at once: one FIN-ACK acknowledges the peer's FIN and carries ours.
            finQueued = true
            state = .lastAck
            output()
        case .finWait1, .finWait2:
            // ponytail: a FIN before ours is acknowledged (CLOSING) goes straight to TIME_WAIT
            sendAck()
            timeWait()
        default:
            sendAck()
        }
    }

    private func timeWait() {
        state = .timeWait
        setTimer(nil)
        // ponytail: a FIN repeated during TIME_WAIT is ACKed but does not restart the 60 s
        tcp.node.sim.sched.after(TCP_TIME_WAIT) { [self] in
            if state == .timeWait { close() }
        }
    }

    /// Sends what the window allows from `nxt`: the SYN, then full-sized segments (a short one only at the end), then the FIN.
    private func output() {
        if nxt == 0 {
            transmit(state == .synSent ? [.syn] : [.syn, .ack], at: 0, length: 0)
            nxt = 1
            return
        }
        guard state != .synSent && state != .synReceived else { return }
        let window = min(cwnd, peerWindow)
        while nxt < dataEnd {
            let length = min(mss, dataEnd - nxt)
            guard nxt + length - una <= window else { return }
            transmit([.ack], at: nxt, length: length)
            nxt += length
        }
        if finQueued && nxt == dataEnd {
            transmit([.fin, .ack], at: nxt, length: 0)
            nxt += 1
            if state == .established { state = .finWait1 }
        }
    }

    /// A segment that uses sequence space: RFC 6298 timing (Karn: never a retransmission) and timer start (5.1).
    private func transmit(_ flags: TcpFlags, at offset: Int, length: Int) {
        let span = length + (flags.contains(.syn) || flags.contains(.fin) ? 1 : 0)
        if offset < sentMax {
            timed = nil
            if length > 0 { retransmissions += 1 }
        } else if timed == nil {
            timed = (offset + span, now)
        }
        if length > 0 { segmentsSent += 1 }
        sentMax = max(sentMax, offset + span)
        send(flags, at: offset, length: length)
        if deadline == nil { setTimer(now + rto) }
    }

    private func sendAck() {
        send([.ack], at: nxt, length: 0)
    }

    private func send(_ flags: TcpFlags, at offset: Int, length: Int) {
        let s = TcpSegment(srcPort: localPort, dstPort: remotePort, seq: iss &+ UInt32(truncatingIfNeeded: offset),
                           ack: flags.contains(.ack) ? irs &+ UInt32(truncatingIfNeeded: rcvNxt) : 0, flags: flags,
                           window: UInt16(TCP_WINDOW), mss: flags.contains(.syn) ? UInt16(TCP_MSS) : nil, dataLength: length)
        tcp.send(s, from: localIp, to: remoteIp)
    }

    /// One pending scheduler callback at a time: a later deadline re-arms when it fires, an earlier one arms anew (generation check).
    private func setTimer(_ at: Int?) {
        deadline = at
        guard let at, armedAt.map({ at < $0 }) ?? true else { return }
        timerGen += 1
        let gen = timerGen
        armedAt = at
        tcp.node.sim.sched.at(at) { [self] in
            guard gen == timerGen else { return }
            armedAt = nil
            guard let due = deadline, state != .closed else { return }
            if now < due { return setTimer(due) }
            deadline = nil
            timeout()
        }
    }

    /// RFC 6298 (5.4)–(5.6): back off and go back to the oldest unacknowledged byte; RFC 5681 (4): half the flight, one segment.
    private func timeout() {
        retries += 1
        guard retries <= TCP_MAX_RETRIES else { return fail(.timedOut) }
        if state == .synSent || state == .synReceived {
            synRetransmitted = true
        } else {
            ssthresh = max((sentMax - una) / 2, 2 * mss)
            cwnd = mss
        }
        dupAcks = 0
        recovering = false
        rto = min(rto * 2, TCP_MAX_RTO)
        timed = nil
        nxt = una
        output()
    }

    private func fail(_ f: TcpFailure) {
        failure = f
        close()
    }

    private func close() {
        abandon()
        tcp.remove(self)
    }
}

/// A node's TCP: listening ports and open connections (both ordered, for deterministic display).
final class Tcp {
    unowned let node: IpNode
    private(set) var listening: [UInt16] = []
    private(set) var connections: [TcpConnection] = []

    init(node: IpNode) {
        self.node = node
    }

    func listen(_ port: UInt16) throws {
        guard !listening.contains(port) else { throw EngineError("TCP port \(port) already in use") }
        listening.append(port)
    }

    func unlisten(_ port: UInt16) {
        listening.removeAll { $0 == port }
    }

    /// Active open from a random ephemeral port (Linux range 32768–60999): sends `bytes`, then closes.
    func connect(to dst: UInt32, port: UInt16, sending bytes: Int) throws -> TcpConnection {
        guard let src = node.sourceFor(dst) else { throw EngineError("Network is unreachable") }
        for _ in 0..<16 {
            let local = UInt16(32768 + node.sim.rng.int(28232))
            guard !connections.contains(where: { $0.localPort == local }) else { continue }
            let c = TcpConnection(tcp: self, local: src, localPort: local, remote: dst, remotePort: port, sending: bytes, state: .synSent)
            connections.append(c)
            c.open()
            return c
        }
        throw EngineError("No free local port")
    }

    func input(_ p: Ipv4Packet, _ s: TcpSegment) {
        guard node.ownsIp(p.dst) else { return } // never to a broadcast address
        if let c = connections.first(where: {
            $0.localIp == p.dst && $0.localPort == s.dstPort && $0.remoteIp == p.src && $0.remotePort == s.srcPort
        }) {
            return c.receive(s)
        }
        if s.flags.contains(.rst) { return }
        if s.flags == [.syn], listening.contains(s.dstPort) {
            let c = TcpConnection(tcp: self, local: p.dst, localPort: s.dstPort, remote: p.src, remotePort: s.srcPort, sending: 0,
                                  state: .synReceived)
            connections.append(c)
            return c.accept(s)
        }
        refuse(p, s)
    }

    /// RFC 793 "Reset Generation": a segment for no connection gets a RST its sender will accept.
    private func refuse(_ p: Ipv4Packet, _ s: TcpSegment) {
        let rst: TcpSegment
        if s.flags.contains(.ack) {
            rst = TcpSegment(srcPort: s.dstPort, dstPort: s.srcPort, seq: s.ack, ack: 0, flags: [.rst], window: 0)
        } else {
            let length = UInt32(s.dataLength) + (s.flags.contains(.syn) ? 1 : 0) + (s.flags.contains(.fin) ? 1 : 0)
            rst = TcpSegment(srcPort: s.dstPort, dstPort: s.srcPort, seq: 0, ack: s.seq &+ length, flags: [.rst, .ack], window: 0)
        }
        send(rst, from: p.dst, to: p.src)
    }

    func send(_ s: TcpSegment, from src: UInt32, to dst: UInt32) {
        node.sendPacket(dst, .tcp(makeTcp(s, src: src, dst: dst)), src: src)
    }

    func remove(_ c: TcpConnection) {
        connections.removeAll { $0 === c }
    }

    /// Power cycle: connections vanish (the peer learns it from a RST later); listening ports are configuration and stay.
    func reset() {
        let all = connections
        connections = []
        for c in all { c.abandon() }
    }
}
