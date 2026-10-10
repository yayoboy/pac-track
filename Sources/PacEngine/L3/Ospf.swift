/// OSPFv2 timers in ns (RFC 2328 Appendix C, IOS defaults, spec M8 §4): Hello and dead intervals; the wait timer equals the
/// dead interval.
let OSPF_HELLO_NS = OSPF_HELLO_S * S
let OSPF_DEAD_NS = OSPF_DEAD_S * S

/// IOS cost (spec M8 §4): reference bandwidth 100 Mb/s over the cable's bandwidth, at least 1.
func ospfCost(_ bandwidthBps: Double) -> Int {
    max(1, Int(100e6 / bandwidthBps))
}

/// RFC 2328 §10.1 neighbour states (Attempt only exists on NBMA networks).
enum OspfNbrState: Int, Comparable {
    case down, initial, twoWay, exStart, exchange, loading, full

    static func < (a: OspfNbrState, b: OspfNbrState) -> Bool { a.rawValue < b.rawValue }

    var label: String { ["Down", "Init", "2-Way", "ExStart", "Exchange", "Loading", "Full"][rawValue] }
}

/// RFC 2328 §9.1 interface states (Loopback is not modelled; a passive interface runs no state machine).
enum OspfIfState: String {
    case down = "Down", waiting = "Waiting", pointToPoint = "Point-to-point", drOther = "DROther", backup = "Backup", dr = "DR"
}

/// A router heard on an OSPF interface, known by its router ID (spec M8 §4).
final class OspfNeighbor {
    let id: UInt32
    var addr: UInt32
    var priority: Int
    /// The DR and BDR its last Hello declared (interface addresses; 0: none).
    var dr: UInt32 = 0
    var bdr: UInt32 = 0
    var state = OspfNbrState.down
    var deadDue: Int?

    init(id: UInt32, addr: UInt32, priority: Int) {
        self.id = id
        self.addr = addr
        self.priority = priority
    }
}

/// An interface running OSPF: its address and cost, its state machine and the routers heard on it.
final class OspfInterface {
    let iface: Interface
    var config: OspfInterfaceConfig
    let addr: UInt32
    let prefix: Int
    var cost: Int
    var state = OspfIfState.down
    /// DR and BDR as this router sees them (interface addresses; 0: none).
    var dr: UInt32 = 0
    var bdr: UInt32 = 0
    var neighbors: [OspfNeighbor] = []
    var helloDue: Int?
    var waitDue: Int?

    init(iface: Interface, config: OspfInterfaceConfig, cidr: Cidr, cost: Int) {
        self.iface = iface
        self.config = config
        addr = cidr.addr
        prefix = cidr.prefix
        self.cost = cost
    }
}

/// OSPFv2 in area 0 on one router (RFC 2328, spec M8 §4). Timers are deadlines checked in `expire`: an expiry does nothing if
/// its deadline was moved or cleared since.
// ponytail: linear scans of arrays; a lab has a handful of interfaces, neighbours and LSAs
final class Ospf {
    unowned let node: IpNode
    private(set) var config: OspfConfig
    /// Chosen when the process starts (spec M8 §4); 0 until then.
    private(set) var routerId: UInt32 = 0
    /// Interfaces taking part, not passive, with an address and the line up, in the router's order.
    private(set) var interfaces: [OspfInterface] = []
    private var running = false
    private var startDue: Int?

    init(node: IpNode, config: OspfConfig) {
        self.node = node
        self.config = config
    }

    private var now: Int { node.sim.now }

    /// OSPF on, or the router powered on. The process boots from the scheduler, so a router switched off in the same instant
    /// (a file opening with it off, undo) says nothing.
    func start() {
        guard !running else { return }
        running = true
        startDue = arm(now)
    }

    /// OSPF off or power off: everything is forgotten at once and nothing is sent.
    func stop() {
        running = false
        startDue = nil
        interfaces = []
    }

    /// New settings; a new router ID waits for the process to restart (spec M8 §4).
    func reconfigure(_ new: OspfConfig) {
        config = new
        refresh()
    }

    /// The configured router ID, else the highest address on an interface whose line is up, else on any interface.
    private func boot() {
        routerId = config.routerId.flatMap { try? parseIp($0) }
            ?? node.interfaces.filter(\.lineUp).compactMap { $0.ipv4?.addr }.max()
            ?? node.interfaces.compactMap { $0.ipv4?.addr }.max()
            ?? routerId
        refresh()
    }

    /// Brings the interfaces in line with configuration, addresses and lines: one that left, lost its line or its address, or
    /// changed network type goes down with its neighbours (KillNbr); a new one comes up; priority and cost follow at once.
    func refresh() {
        guard running, startDue == nil else { return }
        let wanted = config.interfaces.compactMap { c -> (Interface, OspfInterfaceConfig, Cidr)? in
            guard !c.passive, let i = try? node.iface(c.name), let a = i.ipv4, i.lineUp else { return nil }
            return (i, c, a)
        }
        for oi in interfaces where !wanted.contains(where: {
            $0.0 === oi.iface && $0.2 == Cidr(addr: oi.addr, prefix: oi.prefix) && $0.1.pointToPoint == oi.config.pointToPoint
        }) {
            interfaceDown(oi)
        }
        for (i, c, a) in wanted {
            if let oi = interfaces.first(where: { $0.iface === i }) {
                oi.config = c
                oi.cost = cost(i)
            } else {
                interfaceUp(OspfInterface(iface: i, config: c, cidr: a, cost: cost(i)))
            }
        }
        let order = node.interfaces
        interfaces.sort { a, b in (order.firstIndex { $0 === a.iface } ?? 0) < (order.firstIndex { $0 === b.iface } ?? 0) }
    }

    /// RFC 2328 §8.2: only from a neighbour on the subnet of an interface running OSPF; AllDRouters only reaches the DR and the BDR.
    func receive(_ p: Ipv4Packet, _ o: OspfPacket, on iface: Interface) {
        guard running, let oi = interfaces.first(where: { $0.iface === iface }), o.routerId != routerId, inSubnet(p.src, oi.addr, oi.prefix),
              p.dst != OSPF_ALL_DROUTERS || oi.state == .dr || oi.state == .backup else { return }
        if case .hello(let h) = o.body { hello(h, from: o.routerId, addr: p.src, on: oi) }
    }

    private func cost(_ i: Interface) -> Int {
        ospfCost((i.dot1q?.parent ?? i).link?.opts.bandwidthBps ?? 1e9)
    }

    // MARK: Interfaces and neighbours (RFC 2328 §9–10)

    /// InterfaceUp (RFC 2328 §9.3): point-to-point at once; on a broadcast network Waiting for the wait timer, or DROther with
    /// priority 0. The first Hello leaves now.
    private func interfaceUp(_ oi: OspfInterface) {
        interfaces.append(oi)
        setState(oi, oi.config.pointToPoint ? .pointToPoint : oi.config.priority == 0 ? .drOther : .waiting)
        if oi.state == .waiting { oi.waitDue = arm(now + OSPF_DEAD_NS) }
        sendHello(oi)
        oi.helloDue = arm(now + OSPF_HELLO_NS)
    }

    /// InterfaceDown: its neighbours are killed and it leaves.
    private func interfaceDown(_ oi: OspfInterface) {
        for n in oi.neighbors { setState(n, on: oi, .down) }
        oi.neighbors = []
        setState(oi, .down)
        oi.helloDue = nil
        oi.waitDue = nil
        interfaces.removeAll { $0 === oi }
    }

    /// RFC 2328 §10.5.
    private func hello(_ h: OspfHello, from id: UInt32, addr: UInt32, on oi: OspfInterface) {
        // On a broadcast network the masks must match; the intervals always do, they are not configurable.
        guard oi.config.pointToPoint || h.prefix == oi.prefix else { return }
        let known = oi.neighbors.first { $0.id == id }
        let n = known ?? OspfNeighbor(id: id, addr: addr, priority: h.priority)
        if known == nil { oi.neighbors.append(n) }
        let changed = known != nil && (n.priority != h.priority || (n.dr == n.addr) != (h.dr == addr) || (n.bdr == n.addr) != (h.bdr == addr))
        n.addr = addr
        n.priority = h.priority
        n.dr = h.dr
        n.bdr = h.bdr
        if known == nil { setState(n, on: oi, .initial) }
        n.deadDue = arm(now + OSPF_DEAD_NS)
        guard h.neighbors.contains(routerId) else {
            // 1-WayReceived: it no longer lists this router.
            if n.state >= .twoWay {
                setState(n, on: oi, .initial)
                neighborChange(oi)
            }
            return
        }
        if n.state == .initial { twoWayReceived(n, on: oi) }
        if oi.state == .waiting && ((h.dr == addr && h.bdr == 0) || h.bdr == addr) {
            // BackupSeen: the network already has a BDR, or a DR without one.
            oi.waitDue = nil
            elect(oi)
        } else if changed {
            neighborChange(oi)
        }
    }

    /// 2-WayReceived (RFC 2328 §10.3).
    private func twoWayReceived(_ n: OspfNeighbor, on oi: OspfInterface) {
        if adjacencyWanted(n, on: oi) { startExchange(n, on: oi) } else { setState(n, on: oi, .twoWay) }
        neighborChange(oi)
    }

    /// RFC 2328 §10.4: always on point-to-point; on a broadcast network only with, or as, the DR or the BDR.
    private func adjacencyWanted(_ n: OspfNeighbor, on oi: OspfInterface) -> Bool {
        oi.config.pointToPoint || [oi.addr, n.addr].contains(oi.dr) || [oi.addr, n.addr].contains(oi.bdr)
    }

    /// ExStart (RFC 2328 §10.3): the database exchange begins.
    private func startExchange(_ n: OspfNeighbor, on oi: OspfInterface) {
        setState(n, on: oi, .exStart)
    }

    /// NeighborChange: the election runs again once the wait is over.
    private func neighborChange(_ oi: OspfInterface) {
        if oi.state == .dr || oi.state == .backup || oi.state == .drOther { elect(oi) }
    }

    /// InactivityTimer or KillNbr: the neighbour is forgotten; losing a two-way neighbour runs the election again.
    private func neighborDown(_ n: OspfNeighbor, on oi: OspfInterface) {
        let was = n.state
        setState(n, on: oi, .down)
        oi.neighbors.removeAll { $0 === n }
        if was >= .twoWay { neighborChange(oi) }
    }

    /// RFC 2328 §9.4: the BDR among the routers not declaring themselves DR (those declaring BDR first), the DR among those
    /// declaring DR, else the new BDR; highest priority, then router ID; once more when this router's own role changed. A
    /// router that arrives later never takes a role that is held (no preemption).
    private func elect(_ oi: OspfInterface) {
        struct Candidate {
            let id: UInt32
            let addr: UInt32
            let priority: Int
            let dr: UInt32
            let bdr: UInt32
        }
        func best(_ cs: [Candidate]) -> Candidate? { cs.max { ($0.priority, $0.id) < ($1.priority, $1.id) } }
        func round() {
            let me = oi.config.priority > 0 ? [Candidate(id: routerId, addr: oi.addr, priority: oi.config.priority, dr: oi.dr, bdr: oi.bdr)] : []
            let cs = me + oi.neighbors.filter { $0.state >= .twoWay && $0.priority > 0 }
                .map { Candidate(id: $0.id, addr: $0.addr, priority: $0.priority, dr: $0.dr, bdr: $0.bdr) }
            let notDr = cs.filter { $0.dr != $0.addr }
            let bdr = best(notDr.filter { $0.bdr == $0.addr }) ?? best(notDr)
            oi.dr = (best(cs.filter { $0.dr == $0.addr }) ?? bdr)?.addr ?? 0
            oi.bdr = bdr?.addr ?? 0
        }
        let role = (oi.dr == oi.addr, oi.bdr == oi.addr)
        round()
        if (oi.dr == oi.addr, oi.bdr == oi.addr) != role { round() }
        setState(oi, oi.dr == oi.addr ? .dr : oi.bdr == oi.addr ? .backup : .drOther)
        // AdjOK? (RFC 2328 §10.3)
        for n in oi.neighbors where n.state >= .twoWay {
            let wanted = adjacencyWanted(n, on: oi)
            if n.state == .twoWay && wanted {
                startExchange(n, on: oi)
            } else if n.state >= .exStart && !wanted {
                setState(n, on: oi, .twoWay)
            }
        }
    }

    private func setState(_ oi: OspfInterface, _ s: OspfIfState) {
        guard oi.state != s else { return }
        log(oi, "\(oi.state.rawValue) → \(s.rawValue)")
        oi.state = s
    }

    /// Every change is a state event with protocol OSPF (spec M8 §4).
    private func setState(_ n: OspfNeighbor, on oi: OspfInterface, _ s: OspfNbrState) {
        guard n.state != s else { return }
        log(oi, "vicino \(formatIp(n.id)): \(n.state.label) → \(s.label)")
        n.state = s
        if s == .down { n.deadDue = nil }
    }

    private func log(_ oi: OspfInterface, _ note: String) {
        node.sim.emit(.state, node: node.id, iface: oi.iface.name, note: note, proto: .ospf)
    }

    // MARK: Packets

    private func sendHello(_ oi: OspfInterface) {
        send(.hello(OspfHello(prefix: oi.prefix, priority: oi.config.priority, dr: oi.dr, bdr: oi.bdr, neighbors: oi.neighbors.map(\.id))),
             on: oi, to: OSPF_ALL_ROUTERS)
    }

    /// Multicast to AllSPFRouters or AllDRouters out of `oi`, or unicast to a neighbour's address, from the interface's address.
    private func send(_ body: OspfBody, on oi: OspfInterface, to dst: UInt32) {
        let p = makeOspf(routerId: routerId, body)
        switch dst {
        case OSPF_ALL_ROUTERS: node.multicast(on: oi.iface, src: oi.addr, group: dst, mac: OSPF_ALL_ROUTERS_MAC, .ospf(p))
        case OSPF_ALL_DROUTERS: node.multicast(on: oi.iface, src: oi.addr, group: dst, mac: OSPF_ALL_DROUTERS_MAC, .ospf(p))
        default: node.sendPacket(dst, .ospf(p), ttl: 1, src: oi.addr)
        }
    }

    // MARK: Timers

    private func arm(_ due: Int) -> Int {
        node.sim.sched.at(due) { [weak self] in self?.expire(due) }
        return due
    }

    private func expire(_ due: Int) {
        if startDue == due {
            startDue = nil
            boot()
        }
        for oi in interfaces {
            // The election first, so a Hello due at the same instant already carries its result.
            if oi.waitDue == due {
                oi.waitDue = nil
                elect(oi)
            }
            if oi.helloDue == due {
                oi.helloDue = arm(due + OSPF_HELLO_NS)
                sendHello(oi)
            }
            for n in oi.neighbors where n.deadDue == due { neighborDown(n, on: oi) }
        }
    }
}
