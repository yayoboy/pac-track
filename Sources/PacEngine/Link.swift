/// Defaults: 1 Gb/s copper, ~100 m.
struct LinkOptions: Sendable {
    var bandwidthBps: Double = 1e9
    var propDelayNs = 500
    var lossRate = 0.0
    var queueLimit = 1000
}

private final class Direction {
    var queue: [EthernetFrame] = []
    var busy = false
}

/// Full-duplex point-to-point link with a FIFO tail-drop queue per direction.
final class Link {
    var up = true
    let opts: LinkOptions
    unowned let sim: Sim
    unowned let a: Interface
    unowned let b: Interface
    private let dirA = Direction()
    private let dirB = Direction()

    init(sim: Sim, _ a: Interface, _ b: Interface, _ opts: LinkOptions = LinkOptions()) throws {
        guard a.node !== b.node else { throw EngineError("Cannot connect a node to itself") }
        guard a.link == nil, b.link == nil else { throw EngineError("Interface already connected: \(a.link != nil ? a.id : b.id)") }
        guard opts.bandwidthBps > 0, opts.propDelayNs >= 0, (0...1).contains(opts.lossRate), opts.queueLimit >= 0 else {
            throw EngineError("Invalid link options: \(opts)")
        }
        self.sim = sim
        self.a = a
        self.b = b
        self.opts = opts
        a.link = self
        b.link = self
    }

    func peer(_ i: Interface) -> Interface { i === a ? b : a }

    private func direction(_ from: Interface) -> Direction { from === a ? dirA : dirB }

    func transmit(from: Interface, _ frame: EthernetFrame) {
        guard up else { return drop(at: from, frame, .linkDown) }
        let dir = direction(from)
        if !dir.busy { return startTx(from, dir, frame) }
        guard dir.queue.count < opts.queueLimit else { return drop(at: from, frame, .queueFull) }
        dir.queue.append(frame)
    }

    private func startTx(_ from: Interface, _ dir: Direction, _ frame: EthernetFrame) {
        dir.busy = true
        sim.emit(.tx, node: from.node.id, iface: from.name, frame: frame)
        // At least 1 ns, so time always advances (a zero-time loop would never end).
        let txNs = max(1, Int((Double(frame.wireBytes * 8) * Double(S) / opts.bandwidthBps).rounded()))
        sim.sched.after(txNs) { [self] in
            let to = peer(from)
            let lost = opts.lossRate > 0 && sim.rng.next() < opts.lossRate
            sim.sched.after(opts.propDelayNs) { [self] in arrive(to, frame, lost) }
            if dir.queue.isEmpty {
                dir.busy = false
            } else {
                startTx(from, dir, dir.queue.removeFirst())
            }
        }
    }

    private func arrive(_ to: Interface, _ frame: EthernetFrame, _ lost: Bool) {
        if lost { return drop(at: to, frame, .loss) }
        guard up, to.up, to.node.powered else { return drop(at: to, frame, .linkDown) }
        sim.emit(.rx, node: to.node.id, iface: to.name, frame: frame)
        to.node.receive(frame, on: to)
    }

    private func drop(at iface: Interface, _ frame: EthernetFrame, _ reason: DropReason) {
        sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: frame, reason: reason)
    }
}
