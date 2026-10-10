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
    /// Traffic generator flows by id: the sink that receives one of a flow's datagrams hands it back here.
    var flows: [Int: (TrafficData) -> Void] = [:]
    private var ids = 0
    private var macs = 0
    /// The simulation owns its nodes (nodes refer back `unowned`), so a node lives exactly as long as its Sim.
    private var nodes: [Node] = []
    /// Removed devices: kept alive while frames on their cables finish (links refer to their interfaces `unowned`), out of the network.
    private var removed: [Node] = []
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
              packet: Ipv4Packet? = nil, reason: DropReason? = nil, note: String? = nil) {
        log.push(SimEvent(time: now, kind: kind, node: node, iface: iface, frame: frame, packet: packet, reason: reason, note: note))
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

    /// A deleted device leaves the network: its VLANs stop existing, so the switches update their PVST+ instances.
    func remove(_ node: Node) {
        nodes.removeAll { $0 === node }
        removed.append(node)
        syncStp()
    }

    /// VLANs in the network: one exists where a switch port uses it as access or native VLAN (spec M7 §2: no VLAN database).
    func vlans() -> Set<Int> {
        Set(nodes.compactMap { $0 as? Switch }.flatMap { sw in
            sw.interfaces.map { $0.switchport.config.mode == .access ? $0.switchport.config.vlan : $0.switchport.config.native }
        })
    }

    /// A port's VLANs changed somewhere: every switch brings its PVST+ instances in line.
    func syncStp() {
        for case let sw as Switch in nodes { sw.syncStp() }
    }

    func run(_ duration: Int) {
        sched.runUntil(now + duration)
    }
}
