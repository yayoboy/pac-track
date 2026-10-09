/// Defaults: 1 Gb/s copper, ~100 m.
public struct LinkOptions: Codable, Equatable, Sendable {
    public var bandwidthBps: Double
    public var propDelayNs: Int
    public var lossRate: Double
    public var queueLimit: Int

    public init(bandwidthBps: Double = 1e9, propDelayNs: Int = 500, lossRate: Double = 0, queueLimit: Int = 1000) {
        self.bandwidthBps = bandwidthBps
        self.propDelayNs = propDelayNs
        self.lossRate = lossRate
        self.queueLimit = queueLimit
    }
}

/// Upper bound keeps timer arithmetic far from overflow (a geostationary hop is ~0.25 s).
private let MAX_PROP_DELAY_NS = 10 * S

func validateLinkOptions(_ o: LinkOptions) throws {
    let problem: String? =
        !(o.bandwidthBps >= 1) ? "bandwidth must be at least 1 b/s"
        : !(0...MAX_PROP_DELAY_NS).contains(o.propDelayNs) ? "propagation delay must be between 0 and 10 s"
        : !(0...1).contains(o.lossRate) ? "loss rate must be between 0 and 100%"
        : o.queueLimit < 0 ? "queue limit cannot be negative"
        : nil
    if let problem { throw EngineError("Invalid link options: \(problem)") }
}

/// Totals for one direction of a cable since it was plugged; the runtime turns them into 100 ms points.
struct LinkCounters {
    var busyNs = 0
    var drops = 0
    var queued = 0
}

private final class Direction {
    var queue: [EthernetFrame] = []
    var busy = false
    var busyNs = 0
    var drops = 0

    var counters: LinkCounters { LinkCounters(busyNs: busyNs, drops: drops, queued: queue.count) }
}

/// Full-duplex point-to-point link with a FIFO tail-drop queue per direction.
final class Link {
    var up = true {
        didSet { if up != oldValue { notify() } }
    }
    private(set) var opts: LinkOptions
    unowned let sim: Sim
    unowned let a: Interface
    unowned let b: Interface
    private let dirA = Direction()
    private let dirB = Direction()

    init(sim: Sim, _ a: Interface, _ b: Interface, _ opts: LinkOptions = LinkOptions()) throws {
        guard a.node !== b.node else { throw EngineError("Cannot connect a node to itself") }
        guard a.dot1q == nil && b.dot1q == nil else { throw EngineError("Cannot cable a subinterface") }
        guard a.link == nil, b.link == nil else { throw EngineError("Interface already connected: \(a.link != nil ? a.id : b.id)") }
        try validateLinkOptions(opts)
        self.sim = sim
        self.a = a
        self.b = b
        self.opts = opts
        a.link = self
        b.link = self
        notify()
    }

    func peer(_ i: Interface) -> Interface { i === a ? b : a }

    /// Both ends see a change of the cable at once (spec M7 §4).
    private func notify() {
        a.node.linkChanged(a)
        b.node.linkChanged(b)
    }

    /// From `a` to `b`, and back.
    func counters() -> (ab: LinkCounters, ba: LinkCounters) {
        (dirA.counters, dirB.counters)
    }

    /// New options apply to frames that start transmitting from now on; queued frames keep waiting.
    func update(_ opts: LinkOptions) throws {
        try validateLinkOptions(opts)
        self.opts = opts
        notify() // a new bandwidth is a new STP path cost
    }

    /// Pulls the cable: both interfaces become free, frames in flight are lost.
    func disconnect() {
        up = false
        a.link = nil
        b.link = nil
    }

    private func direction(_ from: Interface) -> Direction { from === a ? dirA : dirB }

    func transmit(from: Interface, _ frame: EthernetFrame) {
        let dir = direction(from)
        guard up else { return drop(at: from, frame, .linkDown, dir) }
        if !dir.busy { return startTx(from, dir, frame) }
        guard dir.queue.count < opts.queueLimit else { return drop(at: from, frame, .queueFull, dir) }
        dir.queue.append(frame)
    }

    private func startTx(_ from: Interface, _ dir: Direction, _ frame: EthernetFrame) {
        dir.busy = true
        sim.emit(.tx, node: from.node.id, iface: from.name, frame: frame)
        // At least 1 ns, so time always advances (a zero-time loop would never end).
        let txNs = max(1, Int((Double(frame.wireBytes * 8) * Double(S) / opts.bandwidthBps).rounded()))
        dir.busyNs += txNs
        sim.sched.after(txNs) { [self] in
            let to = peer(from)
            let lost = opts.lossRate > 0 && sim.rng.next() < opts.lossRate
            sim.sched.after(opts.propDelayNs) { [self] in arrive(to, frame, lost, dir) }
            if up, from.node.powered, !dir.queue.isEmpty {
                startTx(from, dir, dir.queue.removeFirst())
            } else {
                dir.busy = false
                // A fault or a powered-off sender loses what was waiting, and says so.
                for queued in dir.queue { drop(at: from, queued, up ? .ifaceDown : .linkDown, dir) }
                dir.queue.removeAll()
            }
        }
    }

    private func arrive(_ to: Interface, _ frame: EthernetFrame, _ lost: Bool, _ dir: Direction) {
        if lost { return drop(at: to, frame, .loss, dir) }
        guard up, to.up, to.node.powered else { return drop(at: to, frame, .linkDown, dir) }
        sim.emit(.rx, node: to.node.id, iface: to.name, frame: frame)
        to.node.receive(frame, on: to)
    }

    private func drop(at iface: Interface, _ frame: EthernetFrame, _ reason: DropReason, _ dir: Direction) {
        dir.drops += 1
        sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: frame, reason: reason)
    }
}
