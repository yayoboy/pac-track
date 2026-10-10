/// RIPv2 timers (RFC 2453, spec M8 §3; not configurable): updates every 30 s, timeout 180 s, garbage collection 120 s.
let RIP_UPDATE_NS = 30 * S
let RIP_TIMEOUT_NS = 180 * S
let RIP_GARBAGE_NS = 120 * S
/// Least time between two triggered updates: RFC 2453 §3.10.1 draws 1–5 s at random, here the low end, so times stay exact.
let RIP_TRIGGER_GAP_NS = 1 * S

extension Interface {
    /// IOS "up/up" (spec M8 §2): the device is on, the interface not deleted, its cable (a subinterface's: the physical one's)
    /// plugged and not failed, and the device at the other end on.
    var lineUp: Bool {
        let phys = dot1q?.parent ?? self
        guard node.powered, up, let link = phys.link, link.up else { return false }
        return link.peer(phys).node.powered
    }
}

/// One route of the RIP database: a connected network taking part (no next hop) or one heard from a neighbour.
struct RipRoute {
    let network: UInt32
    let prefix: Int
    var nextHop: UInt32?
    var iface: Interface
    /// Hops as IOS counts them: 0 for a connected network, what the neighbour sent for a learned one; RIP_INFINITY while deleted.
    var metric: Int
    /// Learned routes: expires RIP_TIMEOUT_NS after the last update that confirmed it.
    var timeout: Int?
    /// Set while the route is being deleted (metric 16): removed at this time.
    var garbage: Int?
    /// Changed since the last update sent: goes into the next triggered update.
    var changed = true
}

/// RIPv2 on one router (RFC 2453 §3.9–3.10, spec M8 §3): whole-table requests, periodic and triggered responses with simple
/// split horizon, timeout and garbage collection, IOS metrics (stored as received, + 1 when sent). Timers are deadlines: an
/// expiry does nothing if its deadline was moved or cleared since.
// ponytail: linear scans of a sorted array; a lab has tens of routes
final class Rip {
    unowned let node: IpNode
    var config: RipConfig
    /// Sorted by network and prefix, so updates list them in a stable order.
    private(set) var routes: [RipRoute] = []
    private var updateDue: Int?
    /// The first requests and update leave from the scheduler, so a router switched off in the same instant (a file opening
    /// with it off, undo) never sends them.
    private var startDue: Int?
    private var triggerDue: Int?
    private var quietUntil = 0
    /// Unbinds UDP 520; nil while stopped (RIP off or the router powered off).
    private var unbind: (() -> Void)?

    init(node: IpNode, config: RipConfig) {
        self.node = node
        self.config = config
    }

    private var now: Int { node.sim.now }

    /// RIP on, or the router powered on: listens on UDP 520, then asks the neighbours for their tables and announces the
    /// connected networks; periodic updates follow every 30 s from now.
    func start() {
        guard unbind == nil else { return }
        unbind = try? node.bindUdp(PORT_RIP) { [unowned self] p, u, iface in
            if case .rip(let m) = u.payload, let iface { receive(m, from: p.src, port: u.srcPort, on: iface) }
        }
        updateDue = arm(now + RIP_UPDATE_NS)
        startDue = arm(now)
    }

    /// RIP off or power off: everything learned is forgotten at once and nothing is sent (IOS `no router rip`).
    func stop() {
        unbind?()
        unbind = nil
        routes = []
        updateDue = nil
        startDue = nil
        triggerDue = nil
        quietUntil = 0
        node.routes.learned = []
    }

    /// Brings the database in line with the interfaces after a change of configuration, address or line state: a taking-part
    /// network whose line is up is a connected route, and a new one asks its neighbours for their tables (unless passive); a
    /// connected network that left, and every route learned through an interface whose line went down, start being deleted.
    func refresh() {
        guard unbind != nil else { return }
        let wanted = config.interfaces.compactMap { name -> RipRoute? in
            guard let i = try? node.iface(name), let c = i.ipv4, i.lineUp else { return nil }
            return RipRoute(network: networkOf(c.addr, c.prefix), prefix: c.prefix, nextHop: nil, iface: i, metric: 0)
        }
        for k in routes.indices where routes[k].metric < RIP_INFINITY {
            let r = routes[k]
            // A learned route also goes when its interface leaves RIP or its next hop is no longer on the interface's subnet.
            let stays = r.nextHop.map { hop in
                r.iface.lineUp && config.interfaces.contains(r.iface.name) && (r.iface.ipv4.map { inSubnet(hop, $0.addr, $0.prefix) } ?? false)
            } ?? wanted.contains { $0.network == r.network && $0.prefix == r.prefix && $0.iface === r.iface }
            if !stays { poison(k) }
        }
        for w in wanted {
            if let k = index(w.network, w.prefix) {
                guard routes[k].nextHop != nil || routes[k].metric != 0 else { continue }
                routes[k] = w
            } else {
                insert(w)
            }
            if !config.passive.contains(w.iface.name) {
                multicast(RIP_REQUEST, [RipEntry(afi: 0, network: 0, prefix: 0, metric: RIP_INFINITY)], on: w.iface)
            }
        }
        commit()
    }

    /// RFC 2453 §3.9: only from a neighbour on the subnet of an interface taking part (a passive one too); responses only from port 520.
    private func receive(_ m: RipMessage, from src: UInt32, port: UInt16, on iface: Interface) {
        guard config.interfaces.contains(iface.name), let own = iface.ipv4, inSubnet(src, own.addr, own.prefix), !node.ownsIp(src) else { return }
        if m.command == RIP_REQUEST {
            // A whole-table request (one entry, AFI 0, metric 16): the answer goes straight back to the asker, split horizon applied.
            guard m.entries.count == 1, m.entries[0].afi == 0, m.entries[0].metric == RIP_INFINITY, !config.passive.contains(iface.name) else { return }
            for chunk in chunks(entries(out: iface, changedOnly: false)) {
                node.sendUdp(src, srcPort: PORT_RIP, dstPort: port, payload: .rip(RipMessage(command: RIP_RESPONSE, entries: chunk)), ttl: 1)
            }
            return
        }
        guard m.command == RIP_RESPONSE, port == PORT_RIP else { return }
        for e in m.entries where e.afi == 2 && (1...RIP_INFINITY).contains(e.metric) && (0...32).contains(e.prefix) {
            let network = networkOf(e.network, e.prefix)
            // One of this router's own networks: its connected route always wins.
            let own = node.interfaces.contains { $0.ipv4.map { networkOf($0.addr, $0.prefix) == network && $0.prefix == e.prefix } ?? false }
            if !own { learn(network, e.prefix, e.metric, from: src, on: iface) }
        }
        commit()
    }

    /// RFC 2453 §3.9.2: a new reachable network is added; the current next hop refreshes its route (16: deletion starts);
    /// another router replaces it only with a strictly better metric.
    private func learn(_ network: UInt32, _ prefix: Int, _ metric: Int, from src: UInt32, on iface: Interface) {
        guard let k = index(network, prefix) else {
            if metric < RIP_INFINITY {
                insert(RipRoute(network: network, prefix: prefix, nextHop: src, iface: iface, metric: metric, timeout: arm(now + RIP_TIMEOUT_NS)))
            }
            return
        }
        if routes[k].nextHop == src && routes[k].iface === iface {
            guard metric < RIP_INFINITY else {
                if routes[k].metric < RIP_INFINITY { poison(k) }
                return
            }
            routes[k].timeout = arm(now + RIP_TIMEOUT_NS)
            routes[k].garbage = nil
            if routes[k].metric != metric {
                routes[k].metric = metric
                routes[k].changed = true
            }
        } else if metric < routes[k].metric {
            routes[k] = RipRoute(network: network, prefix: prefix, nextHop: src, iface: iface, metric: metric, timeout: arm(now + RIP_TIMEOUT_NS))
        }
    }

    /// RFC 2453 §3.8 deletion: metric 16, advertised as such until garbage collection removes it.
    private func poison(_ k: Int) {
        routes[k].metric = RIP_INFINITY
        routes[k].timeout = nil
        routes[k].garbage = arm(now + RIP_GARBAGE_NS)
        routes[k].changed = true
    }

    /// After a batch of changes: installs the usable learned routes and schedules a triggered update if anything changed.
    private func commit() {
        node.routes.learned = routes.compactMap { r in
            guard let hop = r.nextHop, r.metric < RIP_INFINITY else { return nil }
            return LearnedRoute(network: r.network, prefix: r.prefix, nextHop: hop, iface: r.iface, metric: r.metric)
        }
        if triggerDue == nil, routes.contains(where: \.changed) { triggerDue = arm(max(now, quietUntil)) }
    }

    private func arm(_ due: Int) -> Int {
        node.sim.sched.at(due) { [weak self] in self?.expire(due) }
        return due
    }

    private func expire(_ due: Int) {
        if startDue == due {
            startDue = nil
            refresh()
        }
        if updateDue == due {
            updateDue = arm(due + RIP_UPDATE_NS)
            send(changedOnly: false)
        }
        if triggerDue == due {
            triggerDue = nil
            if routes.contains(where: \.changed) {
                send(changedOnly: true)
                quietUntil = due + RIP_TRIGGER_GAP_NS
            }
        }
        for k in routes.indices where routes[k].timeout == due { poison(k) }
        routes.removeAll { $0.garbage == due }
        commit()
    }

    /// A response out of every interface taking part that is not passive, has an address and its line up: the whole table, or
    /// only what changed. Either way the changes are now told.
    private func send(changedOnly: Bool) {
        for name in config.interfaces where !config.passive.contains(name) {
            guard let i = try? node.iface(name), i.ipv4 != nil, i.lineUp else { continue }
            multicast(RIP_RESPONSE, entries(out: i, changedOnly: changedOnly), on: i)
        }
        for k in routes.indices { routes[k].changed = false }
    }

    /// Simple split horizon: nothing goes back out of the interface it was learned on (a connected network: its own interface);
    /// a learned route that a connected or static one hides is not advertised. Metric + 1, at most 16.
    private func entries(out: Interface, changedOnly: Bool) -> [RipEntry] {
        routes.filter { $0.iface !== out && (!changedOnly || $0.changed) && ($0.nextHop == nil || !node.routes.shadows($0.network, $0.prefix)) }
            .map { RipEntry(network: $0.network, prefix: $0.prefix, metric: min($0.metric + 1, RIP_INFINITY)) }
    }

    /// At most 25 entries per message (RFC 2453 §4); no entries, no message.
    private func chunks(_ entries: [RipEntry]) -> [[RipEntry]] {
        stride(from: 0, to: entries.count, by: RIP_MAX_ENTRIES).map { Array(entries[$0..<min($0 + RIP_MAX_ENTRIES, entries.count)]) }
    }

    private func multicast(_ command: UInt8, _ entries: [RipEntry], on i: Interface) {
        guard let src = i.ipv4?.addr else { return }
        for chunk in chunks(entries) {
            node.multicast(on: i, src: src, group: RIP_GROUP, mac: RIP_MAC,
                           .udp(makeUdp(srcPort: PORT_RIP, dstPort: PORT_RIP, payload: .rip(RipMessage(command: command, entries: chunk)))))
        }
    }

    private func index(_ network: UInt32, _ prefix: Int) -> Int? {
        routes.firstIndex { $0.network == network && $0.prefix == prefix }
    }

    private func insert(_ r: RipRoute) {
        routes.insert(r, at: routes.firstIndex { ($0.network, $0.prefix) > (r.network, r.prefix) } ?? routes.endIndex)
    }
}
