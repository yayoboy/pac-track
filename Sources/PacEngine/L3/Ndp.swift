/// Neighbour Unreachability Detection (RFC 4861 §7.3, §10; IOS defaults, spec M9 §4): REACH lasts 30 s, the first packet to a
/// STALE entry waits 5 s in DELAY, then PROBE sends up to 3 unicast NS a second apart; address resolution sends up to 3 NS.
let ND_REACHABLE_NS = 30 * S
let ND_DELAY_NS = 5 * S
let ND_MAX_SOLICIT = 3
/// Packets queued while an address resolves, as for ARP.
let ND_PENDING_MAX = ARP_PENDING_MAX

enum NeighborState: String, Sendable {
    case incomplete = "INCMP", reachable = "REACH", stale = "STALE", delay = "DELAY", probe = "PROBE"
}

private final class Neighbor {
    let iface: Interface
    let addr: UInt128
    var mac: Mac?
    var state: NeighborState
    var reachableUntil = 0
    /// INCOMPLETE: what waits for the address.
    var queue: [Ipv6Packet] = []
    var solicits = 0
    /// The next NS (INCOMPLETE, PROBE) or the move to PROBE (DELAY).
    var due: Int?

    init(iface: Interface, addr: UInt128, mac: Mac?, state: NeighborState) {
        self.iface = iface
        self.addr = addr
        self.mac = mac
        self.state = state
    }
}

/// The IPv6 neighbour cache of one node (RFC 4861 §7.2–7.3, spec M9 §4), keyed by interface and address (a link-local address
/// repeats on other links). Entries keep their order of arrival; timers are deadlines checked in `expire`.
// ponytail: linear scans; a lab has a handful of neighbours per node
final class NeighborCache {
    unowned let stack: Ipv6
    private var entries: [Neighbor] = []

    init(stack: Ipv6) {
        self.stack = stack
    }

    private var node: IpNode { stack.node }
    private var now: Int { node.sim.now }

    private func find(_ addr: UInt128, _ iface: Interface) -> Neighbor? {
        entries.first { $0.addr == addr && $0.iface === iface }
    }

    /// REACH turns STALE when its time is over, checked lazily.
    private func state(_ n: Neighbor) -> NeighborState {
        n.state == .reachable && now >= n.reachableUntil ? .stale : n.state
    }

    /// `show ipv6 neighbors`: interfaces in the node's order, then addresses.
    func view() -> [(addr: UInt128, mac: Mac?, state: NeighborState, iface: String)] {
        let order = { (n: Neighbor) in self.node.interfaces.firstIndex { $0 === n.iface } ?? 0 }
        return entries.sorted { (order($0), $0.addr) < (order($1), $1.addr) }.map { ($0.addr, $0.mac, state($0), $0.iface.name) }
    }

    /// Power off: every entry and waiting packet is gone (their timers find nothing).
    func reset() {
        entries = []
    }

    /// IPv6 went off on `iface`, or the interface was deleted.
    func forget(_ iface: Interface) {
        entries.removeAll { $0.iface === iface }
    }

    /// Sends `p` to `addr` on `iface` (RFC 4861 §7.2.2, §7.3.3): an unknown address is resolved first, a STALE entry waits in DELAY.
    func send(_ p: Ipv6Packet, to addr: UInt128, on iface: Interface) {
        guard let n = find(addr, iface) else {
            let fresh = Neighbor(iface: iface, addr: addr, mac: nil, state: .incomplete)
            fresh.queue = [p]
            entries.append(fresh)
            return solicit(fresh)
        }
        switch state(n) {
        case .incomplete:
            if n.queue.count < ND_PENDING_MAX {
                n.queue.append(p)
            } else {
                node.sim.emit(.drop, node: node.id, iface: iface.name, reason: .ndPendingFull, packet6: p)
            }
            return
        case .stale:
            n.state = .delay
            n.due = arm(now + ND_DELAY_NS)
        case .reachable, .delay, .probe:
            break
        }
        frame(p, to: n.mac!, on: iface)
    }

    /// A link-layer address heard in an NS, RS or RA (RFC 4861 §7.2.3, §6.2.6, §6.3.4): a new or changed one is STALE, and what
    /// waited for it leaves.
    func learn(_ addr: UInt128, _ mac: Mac, on iface: Interface) {
        guard let n = find(addr, iface) else {
            entries.append(Neighbor(iface: iface, addr: addr, mac: mac, state: .stale))
            return
        }
        guard n.mac != mac else { return }
        n.mac = mac
        n.state = .stale
        n.due = nil
        flush(n)
    }

    /// A Neighbor Advertisement (RFC 4861 §7.2.5); without an entry it is ignored.
    func advertised(_ addr: UInt128, _ mac: Mac, solicited: Bool, override: Bool, on iface: Interface) {
        guard let n = find(addr, iface) else { return }
        if n.state == .incomplete {
            n.mac = mac
            n.state = solicited ? .reachable : .stale
            n.reachableUntil = now + ND_REACHABLE_NS
            n.due = nil
            return flush(n)
        }
        let changed = n.mac != mac
        if !override && changed {
            if state(n) == .reachable { n.state = .stale }
            return
        }
        n.mac = mac
        if solicited {
            n.state = .reachable
            n.reachableUntil = now + ND_REACHABLE_NS
            n.due = nil
        } else if changed {
            n.state = .stale
            n.due = nil
        }
    }

    private func flush(_ n: Neighbor) {
        let waiting = n.queue
        n.queue = []
        for p in waiting { send(p, to: n.addr, on: n.iface) }
    }

    private func frame(_ p: Ipv6Packet, to mac: Mac, on iface: Interface) {
        node.sendFrame(iface, to: mac, etherType: ETHERTYPE_IPV6, .ipv6(p))
    }

    /// One more NS: to the solicited-node group while resolving, to the neighbour itself while probing. Its source is the waiting
    /// packet's when that is an address of the interface, else the interface's address of the target's scope (RFC 4861 §7.2.2).
    private func solicit(_ n: Neighbor) {
        n.solicits += 1
        n.due = arm(now + ND_RETRANS_NS)
        let usable = (n.iface.v6?.addrs ?? []).filter { $0.state == .preferred }
        let own = n.queue.first.map(\.src).flatMap { s in usable.contains { $0.addr == s } ? s : nil }
        guard let src = own ?? usable.first(where: { isLinkLocal6(n.addr) == ($0.origin == .linkLocal) })?.addr ?? usable.first?.addr else { return }
        let probing = n.state == .probe
        let dst = probing ? n.addr : solicitedNode(n.addr)
        let p = makeIpv6(src: src, dst: dst, hopLimit: 255, payload: .ndp(NdpMessage(body: .ns(target: n.addr, slla: n.iface.mac))))
        frame(p, to: probing ? n.mac! : multicastMac6(dst), on: n.iface)
    }

    private func arm(_ due: Int) -> Int {
        node.sim.sched.at(due) { [weak self] in self?.expire(due) }
        return due
    }

    private func expire(_ due: Int) {
        for n in entries where n.due == due {
            n.due = nil
            switch n.state {
            case .delay:
                n.state = .probe
                n.solicits = 0
                solicit(n)
            case .incomplete, .probe:
                if n.solicits < ND_MAX_SOLICIT {
                    solicit(n)
                    continue
                }
                entries.removeAll { $0 === n }
                for p in n.queue {
                    node.sim.emit(.drop, node: node.id, iface: n.iface.name, reason: .ndTimeout, packet6: p)
                    stack.error(p, type: ICMP6_DEST_UNREACH, code: UNREACH6_ADDRESS)
                }
            case .reachable, .stale:
                break
            }
        }
    }
}
