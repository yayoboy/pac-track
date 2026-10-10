/// OSPFv2 timers in ns (RFC 2328 Appendix C, IOS defaults, spec M8 §4): Hello and dead intervals; the wait timer equals the
/// dead interval.
let OSPF_HELLO_NS = OSPF_HELLO_S * S
let OSPF_DEAD_NS = OSPF_DEAD_S * S
let OSPF_RXMT_NS = 5 * S
/// LSRefreshTime: own LSAs are originated again this often.
let OSPF_REFRESH_NS = 1800 * S
/// IOS `timers throttle spf` initial delay: the SPF runs this long after the first change (spec M8 §4).
let OSPF_SPF_DELAY_NS = 5 * S

/// > 0 when `a` is the more recent instance, < 0 when `b` is, 0 when they are the same (RFC 2328 §13.1).
func newer(_ a: LsaHeader, _ b: LsaHeader) -> Int {
    if a.seq != b.seq { return a.seq > b.seq ? 1 : -1 }
    if a.checksum != b.checksum { return a.checksum > b.checksum ? 1 : -1 }
    if (a.age >= OSPF_MAX_AGE) != (b.age >= OSPF_MAX_AGE) { return a.age >= OSPF_MAX_AGE ? 1 : -1 }
    if abs(a.age - b.age) > 900 { return a.age < b.age ? 1 : -1 } // MaxAgeDiff, 15 minutes
    return 0
}

/// One LSA of the database; its age grows from the time it was installed.
struct LsdbEntry {
    var lsa: Lsa
    var installedAt: Int
}

/// IOS cost (spec M8 §4): reference bandwidth 100 Mb/s over the cable's bandwidth, at least 1 and at most 65535 (the 16-bit
/// metric of a router-LSA link).
func ospfCost(_ bandwidthBps: Double) -> Int {
    min(65535, max(1, Int(100e6 / bandwidthBps)))
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
    /// Database exchange (RFC 2328 §10.6): this router's role, the DD sequence number, the last DBD sent and its retransmission.
    var master = false
    var ddSeq: UInt32 = 0
    var lastDbd: OspfDbd?
    var dbdDue: Int?
    /// LSAs still to ask for (Loading), and those flooded to it and not acknowledged yet.
    var requests: [LsaKey] = []
    var requestDue: Int?
    var rxmt: [LsaKey] = []
    var rxmtDue: Int?

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
    /// The link-state database, sorted by key.
    private(set) var lsdb: [LsdbEntry] = []
    private var originateDue: Int?
    /// Own LSAs that came back newer than ours (after a restart): the next origination goes past them (RFC 2328 §13.4).
    private var stale: Set<LsaKey> = []
    private var spfDue: Int?

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
        lsdb = []
        originateDue = nil
        stale = []
        spfDue = nil
        node.routes.ospf = []
    }

    /// New settings; a new router ID waits for the process to restart (spec M8 §4).
    func reconfigure(_ new: OspfConfig) {
        config = new
        refresh()
    }

    /// The configured router ID, else the highest address on an interface whose line is up, else on any interface; with none
    /// at all the process waits idle until an address appears (IOS NORTRID).
    private func boot() {
        routerId = chooseRouterId()
        refresh()
    }

    private func chooseRouterId() -> UInt32 {
        config.routerId.flatMap { try? parseIp($0) }
            ?? node.interfaces.filter(\.lineUp).compactMap { $0.ipv4?.addr }.max()
            ?? node.interfaces.compactMap { $0.ipv4?.addr }.max()
            ?? 0
    }

    /// Brings the interfaces in line with configuration, addresses and lines: one that left, lost its line or its address, or
    /// changed network type goes down with its neighbours (KillNbr); a new one comes up; priority and cost follow at once.
    func refresh() {
        guard running, startDue == nil else { return }
        if routerId == 0 { routerId = chooseRouterId() }
        guard routerId != 0 else { return }
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
        originate()
    }

    /// RFC 2328 §8.2: only from a neighbour on the subnet of an interface running OSPF; AllDRouters only reaches the DR and the BDR.
    func receive(_ p: Ipv4Packet, _ o: OspfPacket, on iface: Interface) {
        guard running, let oi = interfaces.first(where: { $0.iface === iface }), o.routerId != routerId, inSubnet(p.src, oi.addr, oi.prefix),
              p.dst != OSPF_ALL_DROUTERS || oi.state == .dr || oi.state == .backup else { return }
        if case .hello(let h) = o.body { return hello(h, from: o.routerId, addr: p.src, on: oi) }
        guard let n = oi.neighbors.first(where: { $0.id == o.routerId }) else { return }
        switch o.body {
        case .dbd(let d): dbd(d, from: n, on: oi)
        case .request(let keys): request(keys, from: n, on: oi)
        case .update(let lsas): update(lsas, from: n, on: oi)
        case .ack(let headers): ack(headers, from: n)
        case .hello: break
        }
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

    /// ExStart (RFC 2328 §10.3): claim to be master with a new DD sequence number (the time in ms, spec M8 §4) until the
    /// neighbour answers.
    private func startExchange(_ n: OspfNeighbor, on oi: OspfInterface) {
        setState(n, on: oi, .exStart)
        n.requests = []
        n.rxmt = []
        n.master = true
        n.ddSeq = UInt32(truncatingIfNeeded: now / MS)
        sendDbd(OspfDbd(initial: true, more: true, master: true, seq: n.ddSeq, headers: []), to: n, on: oi)
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
        originate()
    }

    private func setState(_ oi: OspfInterface, _ s: OspfIfState) {
        guard oi.state != s else { return }
        log(oi, "\(oi.state.rawValue) → \(s.rawValue)")
        oi.state = s
    }

    /// Every change is a state event with protocol OSPF (spec M8 §4). Below ExStart the exchange is forgotten; becoming or
    /// ceasing to be Full changes this router's LSAs.
    private func setState(_ n: OspfNeighbor, on oi: OspfInterface, _ s: OspfNbrState) {
        guard n.state != s else { return }
        log(oi, "vicino \(formatIp(n.id)): \(n.state.label) → \(s.label)")
        let wasFull = n.state == .full
        n.state = s
        if s == .down { n.deadDue = nil }
        if s < .exStart {
            n.requests = []
            n.rxmt = []
            n.lastDbd = nil
            n.dbdDue = nil
            n.requestDue = nil
            n.rxmtDue = nil
        }
        if wasFull != (s == .full) { originate() }
    }

    private func log(_ oi: OspfInterface, _ note: String) {
        node.sim.emit(.state, node: node.id, iface: oi.iface.name, note: note, proto: .ospf)
    }

    // MARK: Database exchange (RFC 2328 §10.6–10.8)

    private func sendDbd(_ d: OspfDbd, to n: OspfNeighbor, on oi: OspfInterface) {
        n.lastDbd = d
        send(.dbd(d), on: oi, to: n.addr)
        // The master repeats its DBD until it is answered; in ExStart both sides are master.
        n.dbdDue = n.master ? arm(now + OSPF_RXMT_NS) : nil
    }

    /// The whole database summary goes in one DBD (spec M8 §4); the M bit keeps its RFC meaning.
    private func dbd(_ d: OspfDbd, from n: OspfNeighbor, on oi: OspfInterface) {
        if n.state == .initial { twoWayReceived(n, on: oi) }
        switch n.state {
        case .exStart:
            if d.initial && d.more && d.master && d.headers.isEmpty && n.id > routerId {
                // The neighbour is master: answer with our summary under its sequence number.
                n.master = false
                n.ddSeq = d.seq
                setState(n, on: oi, .exchange)
                sendDbd(OspfDbd(initial: false, more: false, master: false, seq: n.ddSeq, headers: summary()), to: n, on: oi)
            } else if !d.initial && !d.master && d.seq == n.ddSeq && n.id < routerId {
                // The slave answered: we are master.
                setState(n, on: oi, .exchange)
                accept(d.headers, for: n)
                n.ddSeq &+= 1
                sendDbd(OspfDbd(initial: false, more: false, master: true, seq: n.ddSeq, headers: summary()), to: n, on: oi)
            }
        case .exchange where n.master:
            guard !d.master, !d.initial, d.seq == n.ddSeq else {
                if d.master || d.initial || d.seq != n.ddSeq &- 1 { startExchange(n, on: oi) } // SeqNumberMismatch; else a duplicate
                return
            }
            accept(d.headers, for: n)
            if !d.more && n.lastDbd?.more == false {
                exchangeDone(n, on: oi)
            } else {
                n.ddSeq &+= 1
                sendDbd(OspfDbd(initial: false, more: false, master: true, seq: n.ddSeq, headers: []), to: n, on: oi)
            }
        case .exchange:
            if d.master && d.seq == n.ddSeq, let last = n.lastDbd { return send(.dbd(last), on: oi, to: n.addr) } // a duplicate
            guard d.master, !d.initial, d.seq == n.ddSeq &+ 1 else { return startExchange(n, on: oi) }
            n.ddSeq = d.seq
            accept(d.headers, for: n)
            sendDbd(OspfDbd(initial: false, more: false, master: false, seq: n.ddSeq, headers: []), to: n, on: oi)
            if !d.more { exchangeDone(n, on: oi) }
        case .loading, .full:
            if !n.master && d.master && d.seq == n.ddSeq, let last = n.lastDbd {
                send(.dbd(last), on: oi, to: n.addr) // the slave answers a repeated DBD again
            } else if d.initial || d.seq != n.ddSeq {
                startExchange(n, on: oi)
            }
        default:
            break
        }
    }

    /// The database as headers with their current age.
    private func summary() -> [LsaHeader] {
        lsdb.map(header)
    }

    /// Headers the neighbour has and we lack, or have older: to request.
    private func accept(_ headers: [LsaHeader], for n: OspfNeighbor) {
        for h in headers where !n.requests.contains(h.key) {
            if let e = entry(h.key), newer(h, header(e)) <= 0 { continue }
            n.requests.append(h.key)
        }
    }

    private func exchangeDone(_ n: OspfNeighbor, on oi: OspfInterface) {
        n.dbdDue = nil
        if n.requests.isEmpty { return setState(n, on: oi, .full) }
        setState(n, on: oi, .loading)
        sendRequest(n, on: oi)
    }

    private func sendRequest(_ n: OspfNeighbor, on oi: OspfInterface) {
        send(.request(n.requests), on: oi, to: n.addr)
        n.requestDue = arm(now + OSPF_RXMT_NS)
    }

    /// An LSR: the LSAs asked for go back in one LSU; one we do not have restarts the exchange (BadLSReq).
    private func request(_ keys: [LsaKey], from n: OspfNeighbor, on oi: OspfInterface) {
        guard n.state >= .exchange else { return }
        let found = keys.compactMap(entry)
        guard found.count == keys.count else { return startExchange(n, on: oi) }
        send(.update(found.map(outgoing)), on: oi, to: n.addr)
    }

    // MARK: Flooding (RFC 2328 §13)

    /// Newer instances are installed and flooded on; duplicates acknowledge our own floods; for older ones our copy goes back.
    /// Every LSA received is acknowledged at once (spec M8 §4).
    private func update(_ lsas: [Lsa], from n: OspfNeighbor, on oi: OspfInterface) {
        guard n.state >= .exchange else { return }
        var acks: [LsaHeader] = []
        for l in lsas {
            let key = l.header.key
            let mine = entry(key)
            let cmp = mine.map { newer(l.header, header($0)) } ?? 1
            let exchanging = interfaces.contains { $0.neighbors.contains { $0.state == .exchange || $0.state == .loading } }
            if l.header.age >= OSPF_MAX_AGE && mine == nil && !exchanging {
                acks.append(l.header)
            } else if cmp > 0 {
                install(l, from: n, on: oi)
                acks.append(l.header)
                if l.header.adv == routerId {
                    stale.insert(key)
                    originate()
                }
            } else if cmp == 0 {
                n.rxmt.removeAll { $0 == key } // an implied acknowledgement
                acks.append(l.header)
            } else if let mine {
                send(.update([outgoing(mine)]), on: oi, to: n.addr)
            }
            if cmp >= 0 { n.requests.removeAll { $0 == key } }
        }
        if !acks.isEmpty { send(.ack(acks), on: oi, to: oi.config.pointToPoint || oi.state == .dr || oi.state == .backup ? OSPF_ALL_ROUTERS : OSPF_ALL_DROUTERS) }
        if n.state == .loading && n.requests.isEmpty {
            n.requestDue = nil
            setState(n, on: oi, .full)
        }
    }

    private func ack(_ headers: [LsaHeader], from n: OspfNeighbor) {
        for h in headers {
            if let e = entry(h.key), newer(h, header(e)) == 0 { n.rxmt.removeAll { $0 == h.key } }
        }
        if n.rxmt.isEmpty { n.rxmtDue = nil }
    }

    /// RFC 2328 §13.3: onto the retransmission list of every adjacent neighbour but the sender, then out of each interface that
    /// got one, unless it came in there from the DR or the BDR, or this router is the BDR there.
    private func flood(_ l: Lsa, from sender: OspfNeighbor?, on inIf: OspfInterface?) {
        for oi in interfaces {
            var added = false
            for n in oi.neighbors where n.state >= .exchange && n !== sender {
                if !n.rxmt.contains(l.header.key) { n.rxmt.append(l.header.key) }
                if n.rxmtDue == nil { n.rxmtDue = arm(now + OSPF_RXMT_NS) }
                added = true
            }
            guard added else { continue }
            if oi === inIf, let sender, sender.addr == oi.dr || sender.addr == oi.bdr || oi.state == .backup { continue }
            send(.update([l]), on: oi, to: oi.config.pointToPoint || oi.state == .dr || oi.state == .backup ? OSPF_ALL_ROUTERS : OSPF_ALL_DROUTERS)
        }
    }

    /// Every RxmtInterval, what a neighbour has not acknowledged goes again, straight to it.
    private func retransmit(_ n: OspfNeighbor, on oi: OspfInterface) {
        n.rxmt = n.rxmt.filter { entry($0) != nil }
        guard !n.rxmt.isEmpty else {
            n.rxmtDue = nil
            return
        }
        send(.update(n.rxmt.compactMap(entry).map(outgoing)), on: oi, to: n.addr)
        n.rxmtDue = arm(now + OSPF_RXMT_NS)
    }

    /// RFC 2328 §13 (c, b, d): the old instance leaves the retransmission lists, the new one is flooded and stored; own LSAs
    /// are refreshed at LSRefreshTime, the others leave at MaxAge.
    private func install(_ l: Lsa, from sender: OspfNeighbor?, on inIf: OspfInterface?) {
        for oi in interfaces {
            for n in oi.neighbors { n.rxmt.removeAll { $0 == l.header.key } }
        }
        flood(l, from: sender, on: inIf)
        let old = entry(l.header.key)
        lsdb.removeAll { $0.lsa.header.key == l.header.key }
        if old?.lsa.body != l.body || l.header.age >= OSPF_MAX_AGE { scheduleSpf() }
        // ponytail: a MaxAge LSA leaves the database once flooded, not once acknowledged; its retransmissions stop there
        guard l.header.age < OSPF_MAX_AGE else { return }
        lsdb.insert(LsdbEntry(lsa: l, installedAt: now), at: lsdb.firstIndex { $0.lsa.header.key > l.header.key } ?? lsdb.endIndex)
        _ = arm(now + (l.header.adv == routerId ? OSPF_REFRESH_NS : (OSPF_MAX_AGE - l.header.age) * S))
    }

    // MARK: Origination (RFC 2328 §12.4)

    /// Own LSAs are brought up to date once per instant, after everything that happened in it.
    private func originate() {
        if running, startDue == nil, originateDue == nil { originateDue = arm(now) }
    }

    private func originateNow() {
        put(LsaKey(type: 1, id: routerId, adv: routerId), .router(routerLinks()))
        for e in lsdb where e.lsa.header.type == 2 && e.lsa.header.adv == routerId && networkBody(e.lsa.header.id) == nil {
            put(e.lsa.header.key, nil)
        }
        for oi in interfaces {
            if let body = networkBody(oi.addr) { put(LsaKey(type: 2, id: oi.addr, adv: routerId), body) }
        }
    }

    /// Point-to-point: the Full neighbour and the subnet as a stub. Broadcast: a transit link once Full with the DR (or DR with a
    /// Full neighbour), else the subnet as a stub. Passive interfaces with the line up: their subnet as a stub. In the router's order.
    private func routerLinks() -> [RouterLink] {
        var links: [RouterLink] = []
        for i in node.interfaces {
            if let oi = interfaces.first(where: { $0.iface === i }) {
                let stub = RouterLink(type: LINK_STUB, id: networkOf(oi.addr, oi.prefix), data: prefixMask(oi.prefix), metric: oi.cost)
                if oi.config.pointToPoint {
                    if let n = oi.neighbors.first(where: { $0.state == .full }) {
                        links.append(RouterLink(type: LINK_P2P, id: n.id, data: oi.addr, metric: oi.cost))
                    }
                    links.append(stub)
                } else if oi.state != .waiting && oi.neighbors.contains(where: { $0.state == .full && (oi.state == .dr || $0.addr == oi.dr) }) {
                    links.append(RouterLink(type: LINK_TRANSIT, id: oi.dr, data: oi.addr, metric: oi.cost))
                } else {
                    links.append(stub)
                }
            } else if config.interfaces.contains(where: { $0.name == i.name && $0.passive }), let a = i.ipv4, i.lineUp {
                links.append(RouterLink(type: LINK_STUB, id: networkOf(a.addr, a.prefix), data: prefixMask(a.prefix), metric: cost(i)))
            }
        }
        return links
    }

    /// The network-LSA for the network where `addr` is this router's address: only as DR with at least one Full neighbour.
    private func networkBody(_ addr: UInt32) -> LsaBody? {
        guard let oi = interfaces.first(where: { $0.addr == addr && $0.state == .dr }) else { return nil }
        let full = oi.neighbors.filter { $0.state == .full }.map(\.id)
        return full.isEmpty ? nil : .network(prefix: oi.prefix, routers: [routerId] + full)
    }

    /// Originates `body` under `key` when it differs from the current instance (or a newer copy of ours came back), with the
    /// next sequence number; nil flushes the key (premature aging, RFC 2328 §14.1).
    private func put(_ key: LsaKey, _ body: LsaBody?) {
        let old = entry(key)
        guard let body else {
            guard var l = old?.lsa else { return }
            l.header.age = OSPF_MAX_AGE
            return install(l, from: nil, on: nil)
        }
        guard old?.lsa.body != body || stale.contains(key) else { return }
        stale.remove(key)
        install(makeLsa(type: key.type, id: key.id, adv: routerId, seq: old.map { $0.lsa.header.seq &+ 1 } ?? OSPF_INITIAL_SEQ, body: body),
                from: nil, on: nil)
    }

    // MARK: SPF (RFC 2328 §16.1)

    private func scheduleSpf() {
        if running, spfDue == nil { spfDue = arm(now + OSPF_SPF_DELAY_NS) }
    }

    /// Dijkstra over routers and transit networks in one area; a link counts only when its far end links back. Then the stub
    /// networks. One next hop per destination (spec M8 §2: no ECMP); this router's own networks stay connected routes.
    private func spf() {
        enum Vertex: Hashable {
            case router(UInt32)
            case network(UInt32)
        }
        /// The root's outgoing interface and the next router's address (nil: a network the root is on).
        struct Hop {
            let iface: Interface
            let addr: UInt32?
        }
        func lsa(_ v: Vertex) -> Lsa? {
            switch v {
            case .router(let id): entry(LsaKey(type: 1, id: id, adv: id))?.lsa
            case .network(let id): lsdb.first { $0.lsa.header.type == 2 && $0.lsa.header.id == id }?.lsa
            }
        }
        func linksBack(_ l: Lsa, to v: Vertex) -> Bool {
            switch (l.body, v) {
            case (.router(let links), .router(let id)): links.contains { $0.type == LINK_P2P && $0.id == id }
            case (.router(let links), .network(let id)): links.contains { $0.type == LINK_TRANSIT && $0.id == id }
            case (.network(_, let routers), .router(let id)): routers.contains(id)
            case (.network, .network): false
            }
        }
        var done: [Vertex: (dist: Int, hop: Hop?)] = [:]
        var order: [Vertex] = []
        var candidates: [(v: Vertex, dist: Int, hop: Hop?)] = [(.router(routerId), 0, nil)]
        while let i = candidates.indices.min(by: { candidates[$0].dist < candidates[$1].dist }) {
            let c = candidates.remove(at: i)
            done[c.v] = (c.dist, c.hop)
            order.append(c.v)
            guard let l = lsa(c.v) else { continue }
            let edges: [(w: Vertex, cost: Int, data: UInt32)]
            switch l.body {
            case .router(let links):
                edges = links.compactMap { k -> (w: Vertex, cost: Int, data: UInt32)? in
                    k.type == LINK_P2P ? (.router(k.id), k.metric, k.data) : k.type == LINK_TRANSIT ? (.network(k.id), k.metric, k.data) : nil
                }
            case .network(_, let routers):
                edges = routers.map { (.router($0), 0, 0) }
            }
            for e in edges where done[e.w] == nil {
                guard let wl = lsa(e.w), linksBack(wl, to: c.v) else { continue }
                let hop: Hop?
                if let h = c.hop {
                    // Past a network the root is on, the next hop is that router's own address on it.
                    if h.addr == nil, case .network(let net) = c.v, case .router(let links) = wl.body {
                        hop = links.first { $0.type == LINK_TRANSIT && $0.id == net }.map { Hop(iface: h.iface, addr: $0.data) }
                    } else {
                        hop = h
                    }
                } else if let oi = interfaces.first(where: { $0.addr == e.data }) {
                    // From the root: out of the interface the link names; a point-to-point neighbour's address from its Hellos.
                    if case .router(let id) = e.w {
                        hop = oi.neighbors.first { $0.id == id }.map { Hop(iface: oi.iface, addr: $0.addr) }
                    } else {
                        hop = Hop(iface: oi.iface, addr: nil)
                    }
                } else {
                    hop = nil
                }
                guard let hop else { continue }
                let d = c.dist + e.cost
                if let k = candidates.firstIndex(where: { $0.v == e.w }) {
                    if d < candidates[k].dist { candidates[k] = (e.w, d, hop) }
                } else {
                    candidates.append((e.w, d, hop))
                }
            }
        }
        var routes: [LearnedRoute] = []
        func add(_ network: UInt32, _ prefix: Int, _ dist: Int, _ hop: Hop?) {
            guard let hop, let via = hop.addr else { return }
            let r = LearnedRoute(network: networkOf(network, prefix), prefix: prefix, nextHop: via, iface: hop.iface, metric: dist)
            if let k = routes.firstIndex(where: { $0.network == r.network && $0.prefix == r.prefix }) {
                if dist < routes[k].metric { routes[k] = r }
            } else {
                routes.append(r)
            }
        }
        for v in order {
            guard let l = lsa(v), let reached = done[v] else { continue }
            switch (l.body, v) {
            case (.network(let prefix, _), .network(let id)):
                add(id, prefix, reached.dist, reached.hop)
            case (.router(let links), _):
                for s in links where s.type == LINK_STUB { add(s.id, s.data.nonzeroBitCount, reached.dist + s.metric, reached.hop) }
            default:
                break
            }
        }
        node.routes.ospf = routes.sorted { ($0.network, $0.prefix) < ($1.network, $1.prefix) }
    }

    // MARK: Database

    func age(_ e: LsdbEntry) -> Int {
        min(OSPF_MAX_AGE, e.lsa.header.age + (now - e.installedAt) / S)
    }

    private func entry(_ key: LsaKey) -> LsdbEntry? {
        lsdb.first { $0.lsa.header.key == key }
    }

    private func header(_ e: LsdbEntry) -> LsaHeader {
        var h = e.lsa.header
        h.age = age(e)
        return h
    }

    /// The instance as it leaves: one second older (InfTransDelay).
    private func outgoing(_ e: LsdbEntry) -> Lsa {
        var l = e.lsa
        l.header.age = min(OSPF_MAX_AGE, age(e) + 1)
        return l
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
        if originateDue == due {
            originateDue = nil
            originateNow()
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
            for n in oi.neighbors {
                if n.deadDue == due { neighborDown(n, on: oi) }
                if n.dbdDue == due, let d = n.lastDbd {
                    send(.dbd(d), on: oi, to: n.addr)
                    n.dbdDue = arm(due + OSPF_RXMT_NS)
                }
                if n.requestDue == due { sendRequest(n, on: oi) }
                if n.rxmtDue == due { retransmit(n, on: oi) }
            }
        }
        for e in lsdb {
            let h = e.lsa.header
            if h.adv == routerId && e.installedAt + OSPF_REFRESH_NS == due {
                stale.insert(h.key) // LSRefreshTime: same contents, next sequence number
                originate()
            } else if h.adv != routerId && e.installedAt + (OSPF_MAX_AGE - h.age) * S == due {
                lsdb.removeAll { $0.lsa.header.key == h.key }
                scheduleSpf()
            }
        }
        if spfDue == due {
            spfDue = nil
            spf()
        }
    }
}
