/// A frame seen this many times by one L2 device within the window means a loop (a tree delivers it once).
let LOOP_REPEATS = 3
let LOOP_WINDOW_NS = 1 * S
/// A device that warned stays quiet this long.
let LOOP_QUIET_NS = 10 * S
private let LOOP_MEMORY = 1024
private let MAX_WARNINGS = 20

struct SimWarning: Equatable, Sendable {
    let id: Int
    let node: String
    let time: Int
}

final class Sim {
    let sched = Scheduler()
    let rng: Rng
    let log: EventLog
    private var ids = 0
    private var macs = 0
    /// The simulation owns its nodes (nodes refer back `unowned`), so a node lives exactly as long as its Sim.
    private var nodes: [Node] = []
    /// Newest L2 loop warnings, oldest first.
    private(set) var warnings: [SimWarning] = []
    private var warningCount = 0
    /// Per L2 device: frame id → (times seen in the window, first sighting).
    private var l2Seen: [String: [Int: (count: Int, first: Int)]] = [:]
    private var lastWarned: [String: Int] = [:]

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

    /// Hubs and switches report every frame they receive.
    // ponytail: per-device memory of 1024 frame ids, wiped when full (a loop is re-detected within a few frames)
    func noteL2(_ frame: EthernetFrame, at node: String) {
        let seen = l2Seen[node]?[frame.id]
        let entry: (count: Int, first: Int) = seen.map { now - $0.first <= LOOP_WINDOW_NS ? ($0.count + 1, $0.first) : (1, now) } ?? (1, now)
        if l2Seen[node, default: [:]].count >= LOOP_MEMORY { l2Seen[node] = [:] }
        l2Seen[node, default: [:]][frame.id] = entry
        guard entry.count >= LOOP_REPEATS, now - (lastWarned[node] ?? -LOOP_QUIET_NS) >= LOOP_QUIET_NS else { return }
        lastWarned[node] = now
        warningCount += 1
        warnings.append(SimWarning(id: warningCount, node: node, time: now))
        if warnings.count > MAX_WARNINGS { warnings.removeFirst() }
    }

    func adopt(_ node: Node) {
        nodes.append(node)
    }

    func run(_ duration: Int) {
        sched.runUntil(now + duration)
    }
}
