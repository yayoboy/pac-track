final class Sim {
    let sched = Scheduler()
    let rng: Rng
    let log: EventLog
    private var ids = 0
    private var macs = 0
    /// The simulation owns its nodes (nodes refer back `unowned`), so a node lives exactly as long as its Sim.
    private var nodes: [Node] = []

    init(seed: UInt32 = 1, logCapacity: Int = 100_000) {
        rng = Rng(seed: seed)
        log = EventLog(capacity: logCapacity)
    }

    var now: Int { sched.now }

    func nextId() -> Int {
        ids += 1
        return ids
    }

    func newMac() -> Mac {
        macs += 1
        return macFromIndex(macs)
    }

    func emit(_ kind: EventKind, node: String, iface: String? = nil, frame: EthernetFrame? = nil,
              packet: Ipv4Packet? = nil, reason: DropReason? = nil) {
        log.push(SimEvent(time: now, kind: kind, node: node, iface: iface, frame: frame, packet: packet, reason: reason))
    }

    func adopt(_ node: Node) {
        nodes.append(node)
    }

    func run(_ duration: Int) {
        sched.runUntil(now + duration)
    }
}
