import Foundation

/// RFC 4861 RetransTimer (IOS `ipv6 nd ns-interval` 1000 ms): DAD waits this long for an answer (spec M9 §5).
let ND_RETRANS_NS = 1 * S
/// Hop limit of the packets a host or router originates (Linux and IOS default, spec M9 §3).
let HOP_LIMIT6: UInt8 = 64
/// Router Solicitations (spec M9 §5, RFC 7559 as Linux): 4 s after the first, then doubling up to 3600 s, until an RA arrives.
let RS_INTERVAL_NS = 4 * S
let RS_MAX_INTERVAL_NS = 3600 * S
/// Router Advertisements (IOS `ipv6 nd ra interval` 200 s); never two multicast RAs closer than MIN_DELAY_BETWEEN_RAS (RFC 4861 §10).
let RA_INTERVAL_NS = 200 * S
let RA_MIN_GAP_NS = 3 * S

enum AddrOrigin: Sendable {
    case linkLocal, manual, slaac
}

enum DadState: Sendable {
    case tentative, preferred, duplicate
}

typealias Icmp6Listener = (Ipv6Packet, IcmpMessage) -> Void

/// Where a packet leaves: the interface and the neighbour it goes to (the destination itself when it is on the link).
struct NextHop6 {
    let iface: Interface
    let nextHop: UInt128
}

/// One IPv6 address of an interface with its DAD state (RFC 4862 §5.4).
struct Addr6 {
    let addr: UInt128
    let prefix: Int
    let origin: AddrOrigin
    var state = DadState.tentative
    /// While tentative: the next DAD step, sending the NS and then (once `probed`) taking the address; nil until the line is up.
    var dadDue: Int? = nil
    var probed = false
}

/// IPv6 on one interface (spec M9 §2): its settings, addresses and line state.
struct Ipv6Iface {
    var config: Ipv6Config
    /// The link-local address first, then the manual one and the SLAAC ones.
    var addrs: [Addr6]
    /// The line state last seen: DAD runs again when it comes back up (spec M9 §5).
    var lineWasUp: Bool
    /// Hosts: the next RS and the wait after it; nil once an RA arrived.
    var rsDue: Int? = nil
    var rsInterval = RS_INTERVAL_NS
    /// Routers that route: the next multicast RA, and when the last one left.
    var raDue: Int? = nil
    var lastRa: Int? = nil
}

/// A default router learned from an RA (spec M9 §5), valid until `expiresAt`.
struct DefaultRouter {
    let addr: UInt128
    let iface: Interface
    var expiresAt: Int
}

/// IOS `ipv6 route <prefix> <next hop>` (spec M9 §6): the next hop is a global address in a connected prefix.
struct Route6 {
    let network: UInt128
    let prefix: Int
    let nextHop: UInt128
}

/// The IPv6 stack of a host or router (spec M9), idle until an interface turns IPv6 on. Timers are deadlines checked in `expire`,
/// as in `Rip`: an expiry does nothing if its deadline was moved or cleared since.
final class Ipv6 {
    unowned let node: IpNode
    var hopLimit = HOP_LIMIT6
    /// IOS `ipv6 unicast-routing`: forwards, sends RAs, listens to ff02::2 (spec M9 §5).
    private(set) var routing = false
    /// Hosts: the routers RAs announced, in order of arrival; the first one still valid is used.
    private(set) var defaults: [DefaultRouter] = []
    private(set) var statics: [Route6] = []
    private(set) lazy var neighbors = NeighborCache(stack: self)
    /// Ordered (not a dictionary): listener order must be deterministic.
    private var listeners: [(token: Int, listener: Icmp6Listener)] = []
    private var nextToken = 0

    init(node: IpNode) {
        self.node = node
    }

    private var now: Int { node.sim.now }

    /// IPv6 on with these settings, or off with nil (spec M9 §2). A new address starts tentative; DAD runs when the line is up.
    /// SLAAC turned on solicits a router at once (spec M9 §5); turned off, its addresses go.
    func configure(_ name: String, _ config: Ipv6Config?) throws {
        let iface = try node.iface(name)
        guard let config else {
            iface.v6 = nil
            neighbors.forget(iface)
            defaults.removeAll { $0.iface === iface }
            return
        }
        let manual = try config.address.map { try manualAddress($0, on: iface) }
        let slaacOn = config.autoconfig && iface.v6?.config.autoconfig == false
        var v6 = iface.v6 ?? Ipv6Iface(config: config, addrs: [Addr6(addr: linkLocal(iface.mac), prefix: 64, origin: .linkLocal)], lineWasUp: iface.lineUp)
        v6.config = config
        v6.addrs.removeAll {
            $0.origin == .manual && ($0.addr != manual?.addr || $0.prefix != manual?.prefix) || $0.origin == .slaac && !config.autoconfig
        }
        if let manual, !v6.addrs.contains(where: { $0.origin == .manual }) {
            v6.addrs.append(Addr6(addr: manual.addr, prefix: manual.prefix, origin: .manual))
        }
        iface.v6 = v6
        dad(iface)
        if slaacOn && node is Host {
            iface.v6!.rsInterval = RS_INTERVAL_NS
            solicit(iface)
        }
    }

    /// IOS `ipv6 address X/len` rules (spec M9 §2): a unicast global or unique-local address, not the Subnet-Router anycast one,
    /// in a prefix no other interface of the device overlaps.
    private func manualAddress(_ text: String, on iface: Interface) throws -> Cidr6 {
        let t = text.trimmingCharacters(in: .whitespaces)
        let c = try parseCidr6(t)
        guard c.prefix >= 1 else { throw EngineError("Invalid IPv6 prefix: \"\(t)\"") }
        guard c.addr > 1, !isMulticast6(c.addr), !isLinkLocal6(c.addr) else {
            throw EngineError("\(formatIp6(c.addr)) cannot be assigned: it is unspecified, loopback, multicast or link-local")
        }
        if c.prefix <= 126 && c.addr == networkOf6(c.addr, c.prefix) { throw EngineError("\(t) is the Subnet-Router anycast address") }
        for other in node.interfaces where other !== iface {
            if other.v6?.addrs.contains(where: { $0.origin != .linkLocal && inSubnet6(c.addr, $0.addr, min(c.prefix, $0.prefix)) }) == true {
                throw EngineError("\(t) overlaps with \(other.name)")
            }
        }
        return c
    }

    /// An address of this device in use (not tentative, not duplicate), on any interface: the weak host model of Linux and IOS.
    func owns(_ a: UInt128) -> Bool {
        node.interfaces.contains { $0.v6?.addrs.contains { $0.addr == a && $0.state == .preferred } == true }
    }

    /// The NIC filter for `33:33` MACs: a group that `phys` or one of its subinterfaces has joined (spec M9 §2).
    func listens(_ mac: Mac, on phys: Interface) -> Bool {
        node.interfaces.contains { i in (i.dot1q?.parent ?? i) === phys && groups(i).contains { multicastMac6($0) == mac } }
    }

    /// The groups an interface has joined: all-nodes, all-routers on a router that routes, each address's solicited-node group.
    private func groups(_ i: Interface) -> [UInt128] {
        guard let v6 = i.v6 else { return [] }
        return [ALL_NODES] + (routing ? [ALL_ROUTERS] : []) + v6.addrs.map { solicitedNode($0.addr) }
    }

    /// A packet that reached an interface: for a group it joined or an address in use; otherwise forwarded by a router with
    /// `ipv6 unicast-routing`, never with a link-local address (RFC 4291 §2.5.6) nor to one of its own tentative or duplicate ones.
    func input(_ p: Ipv6Packet, on iface: Interface) {
        guard iface.v6 != nil else { return } // IPv6 off: like an unknown EtherType
        if isMulticast6(p.dst) {
            if groups(iface).contains(p.dst) { deliver(p, on: iface) }
            return
        }
        if owns(p.dst) { return deliver(p, on: iface) }
        guard routing, !isLinkLocal6(p.src), !isLinkLocal6(p.dst),
              !node.interfaces.contains(where: { $0.v6?.addrs.contains { $0.addr == p.dst } == true }) else { return }
        if p.hopLimit <= 1 {
            node.sim.emit(.drop, node: node.id, iface: iface.name, reason: .ttlExpired, packet6: p)
            return error(p, type: ICMP6_TIME_EXCEEDED, code: 0)
        }
        guard let hop = lookup(p.dst) else {
            node.sim.emit(.drop, node: node.id, reason: .noRoute, packet6: p)
            return error(p, type: ICMP6_DEST_UNREACH, code: UNREACH6_NO_ROUTE)
        }
        var next = p
        next.hopLimit -= 1
        output(next, via: hop)
    }

    /// A packet for this device; `iface` is nil when it sent the packet to itself.
    private func deliver(_ p: Ipv6Packet, on iface: Interface?) {
        switch p.payload {
        case .ndp(let n):
            if let iface { receive(n, p, on: iface) }
        case .icmp(let m):
            if m.type == ICMP6_ECHO_REQUEST && !isMulticast6(p.dst) {
                // From the address that was pinged, like Linux and IOS.
                send(p.src, .icmp(IcmpMessage(type: ICMP6_ECHO_REPLY, code: 0, checksum: 0, id: m.id, seq: m.seq, data: m.data)), src: p.dst, via: iface)
            }
            for entry in listeners { entry.listener(p, m) }
        case .udp(let u):
            // A port bound on both stacks (spec M9 §10); otherwise Port Unreachable, as in IPv4.
            if let handler = node.udp6[u.dstPort] {
                handler(p, u)
            } else if !isMulticast6(p.dst) {
                error(p, type: ICMP6_DEST_UNREACH, code: UNREACH6_PORT, via: iface)
            }
        case .tcp(let t):
            node.tcp.input(t, from: .v6(p.src), to: .v6(p.dst))
        }
    }

    /// NDP, only from the link itself (hop limit 255, RFC 4861 §6.1, §7.1): DAD (RFC 4862 §5.4.3–5.4.4) and address resolution.
    private func receive(_ n: NdpMessage, _ p: Ipv6Packet, on iface: Interface) {
        guard p.hopLimit == 255 else { return }
        switch n.body {
        case .ns(let target, let slla):
            guard let k = iface.v6!.addrs.firstIndex(where: { $0.addr == target }) else { return }
            switch iface.v6!.addrs[k].state {
            case .tentative:
                if p.src == 0 { duplicate(iface, k) } // another node's DAD for the same address
            case .duplicate:
                break
            case .preferred:
                guard p.src != 0 else {
                    // Another node's DAD for an address in use here: the answer goes to every node (RFC 4861 §7.2.4).
                    return sendNdp(.na(target: target, router: routing, solicited: false, override: true, tlla: iface.mac), src: target, dst: ALL_NODES, on: iface)
                }
                if let slla { neighbors.learn(p.src, slla, on: iface) }
                sendNdp(.na(target: target, router: routing, solicited: true, override: true, tlla: iface.mac), src: target, dst: p.src, on: iface)
            }
        case .na(let target, _, let solicited, let override, let tlla):
            if let k = iface.v6!.addrs.firstIndex(where: { $0.addr == target }) {
                if iface.v6!.addrs[k].state == .tentative { duplicate(iface, k) }
                return
            }
            neighbors.advertised(target, tlla, solicited: solicited, override: override, on: iface)
        case .rs(let slla):
            guard routing, usableLinkLocal(iface) != nil else { return }
            if let slla, p.src != 0 { neighbors.learn(p.src, slla, on: iface) }
            // Answered at once, or MIN_DELAY_BETWEEN_RAS after the last multicast RA (RFC 4861 §6.2.6), without random delay.
            if let last = iface.v6!.lastRa, now < last + RA_MIN_GAP_NS {
                let at = last + RA_MIN_GAP_NS
                if iface.v6!.raDue.map({ $0 > at }) ?? true { iface.v6!.raDue = arm(at) }
            } else {
                advertise(iface)
            }
        case .ra(let ra):
            // Hosts and the Cloud only (spec M9 §5–§6), from a router's link-local address (RFC 4861 §6.1.2).
            guard actsAsHost, isLinkLocal6(p.src) else { return }
            neighbors.learn(p.src, ra.slla, on: iface)
            if ra.hopLimit != 0 { hopLimit = ra.hopLimit }
            iface.v6!.rsDue = nil
            let expiresAt = now + Int(ra.lifetime) * S
            if let k = defaults.firstIndex(where: { $0.addr == p.src && $0.iface === iface }) {
                if ra.lifetime > 0 { defaults[k].expiresAt = expiresAt } else { defaults.remove(at: k) }
            } else if ra.lifetime > 0 {
                defaults.append(DefaultRouter(addr: p.src, iface: iface, expiresAt: expiresAt))
            }
            // SLAAC (RFC 4862 §5.5.3): an autonomous /64 prefix + EUI-64; the lifetimes are not modelled (spec M9 §5).
            guard iface.v6!.config.autoconfig else { return }
            for info in ra.prefixes where info.length == 64 && !isLinkLocal6(info.prefix) {
                let addr = networkOf6(info.prefix, 64) | eui64(iface.mac)
                if !iface.v6!.addrs.contains(where: { $0.addr == addr }) { iface.v6!.addrs.append(Addr6(addr: addr, prefix: 64, origin: .slaac)) }
            }
            dad(iface)
        }
    }

    /// DAD failed: the address is never used (spec M9 §5).
    private func duplicate(_ iface: Interface, _ k: Int) {
        iface.v6!.addrs[k].state = .duplicate
        iface.v6!.addrs[k].dadDue = nil
        node.sim.emit(.state, node: node.id, iface: iface.name, note: "DAD: \(formatIp6(iface.v6!.addrs[k].addr)) duplicato", proto: .ndp)
    }

    private func sendNdp(_ body: NdpBody, src: UInt128, dst: UInt128, on iface: Interface) {
        transmit(makeIpv6(src: src, dst: dst, hopLimit: 255, payload: .ndp(NdpMessage(body: body))), on: iface, nextHop: dst)
    }

    /// Out of `iface` toward `nextHop`: multicast straight to the group's MAC, unicast through the neighbour cache.
    private func transmit(_ p: Ipv6Packet, on iface: Interface, nextHop: UInt128) {
        if isMulticast6(p.dst) { return node.sendFrame(iface, to: multicastMac6(p.dst), etherType: ETHERTYPE_IPV6, .ipv6(p)) }
        neighbors.send(p, to: nextHop, on: iface)
    }

    @discardableResult
    func onIcmp(_ listener: @escaping Icmp6Listener) -> () -> Void {
        nextToken += 1
        let token = nextToken
        listeners.append((token, listener))
        return { [weak self] in self?.listeners.removeAll { $0.token == token } }
    }

    /// Originates a packet (spec M9 §6): to an own address through loopback; a link-local destination leaves `via` the given
    /// interface. False when there is no route or no usable source address.
    @discardableResult
    func send(_ dst: UInt128, _ payload: Ipv6Payload, hopLimit: UInt8? = nil, src: UInt128? = nil, via: Interface? = nil) -> Bool {
        if owns(dst) {
            let p = makeIpv6(src: dst, dst: dst, hopLimit: hopLimit ?? self.hopLimit, payload: payload)
            node.sim.sched.after(0) { [self] in deliver(p, on: nil) }
            return true
        }
        guard let hop = isLinkLocal6(dst) ? via.map({ NextHop6(iface: $0, nextHop: dst) }) : lookup(dst),
              let from = src ?? source(for: dst, out: hop.iface) else { return false }
        output(makeIpv6(src: from, dst: dst, hopLimit: hopLimit ?? self.hopLimit, payload: payload), via: hop)
        return true
    }

    /// The source toward `dst`: itself when it is an own address; nil for a link-local destination (it needs an interface) or
    /// without a route.
    func sourceFor(_ dst: UInt128) -> UInt128? {
        if owns(dst) { return dst }
        guard !isLinkLocal6(dst), let hop = lookup(dst) else { return nil }
        return source(for: dst, out: hop.iface)
    }

    /// No fragmentation, not even at the source (spec M9 §3): a packet over the MTU is dropped with Packet Too Big.
    private func output(_ p: Ipv6Packet, via hop: NextHop6) {
        if p.size > hop.iface.mtu {
            node.sim.emit(.drop, node: node.id, iface: hop.iface.name, reason: .mtuExceeded, packet6: p)
            return error(p, type: ICMP6_PACKET_TOO_BIG, code: 0, mtu: hop.iface.mtu)
        }
        neighbors.send(p, to: hop.nextHop, on: hop.iface)
    }

    /// An ICMPv6 error about `orig` back to its source (RFC 4443 §2.4), quoting as much of it as fits in 1280 B. Never about an
    /// error or NDP, a multicast destination (except Packet Too Big), or an unspecified or multicast source.
    func error(_ orig: Ipv6Packet, type: UInt8, code: UInt8, mtu: Int = 0, via iface: Interface? = nil) {
        if case .icmp(let m) = orig.payload, m.type < 128 { return }
        if case .ndp = orig.payload { return }
        guard orig.src != 0, !isMulticast6(orig.src), type == ICMP6_PACKET_TOO_BIG || !isMulticast6(orig.dst) else { return }
        let quote = Array((serializeHeader(orig) + serializePayload(orig)).prefix(IPV6_MIN_MTU - 48))
        // About a packet for this device: from the address it hit (traceroute's last hop); otherwise from the way back.
        send(orig.src, .icmp(IcmpMessage(type: type, code: code, checksum: 0, id: UInt16(truncatingIfNeeded: mtu >> 16),
                                          seq: UInt16(truncatingIfNeeded: mtu), data: quote)),
             src: owns(orig.dst) ? orig.dst : nil, via: iface)
    }

    /// RFC 6724, simplified (spec M9 §6): the link-local address for a link-local destination; otherwise a usable global address
    /// of the outgoing interface, else of the device.
    func source(for dst: UInt128, out iface: Interface) -> UInt128? {
        let usable = { (i: Interface) in (i.v6?.addrs ?? []).filter { $0.state == .preferred } }
        if isLinkLocal6(dst) { return usable(iface).first { $0.origin == .linkLocal }?.addr }
        return (usable(iface) + node.interfaces.flatMap(usable)).first { $0.origin != .linkLocal }?.addr
    }

    /// The interface and next hop toward `dst` (spec M9 §6): longest prefix first; on equal prefixes connected (0) beats static
    /// (1), which beats the RA's default (2). A static route whose next hop is not reachable does not count.
    func lookup(_ dst: UInt128) -> NextHop6? {
        var best: NextHop6?
        var bestPrefix = -1
        for r in statics where inSubnet6(dst, r.network, r.prefix) && r.prefix > bestPrefix {
            guard let via = connected(r.nextHop) else { continue }
            best = NextHop6(iface: via.iface, nextHop: r.nextHop)
            bestPrefix = r.prefix
        }
        if best == nil, let r = defaults.first(where: { $0.expiresAt > now }) {
            best = NextHop6(iface: r.iface, nextHop: r.addr)
            bestPrefix = 0
        }
        if let c = connected(dst), c.prefix >= bestPrefix { return NextHop6(iface: c.iface, nextHop: dst) }
        return best
    }

    /// `requireReachable: false` restores saved routes whose next hop is not reachable yet (kept inactive, like IOS).
    func addStatic(_ cidr: String, _ nextHop: String, requireReachable: Bool = true) throws {
        let c = try parseCidr6(cidr)
        let hop = try parseIp6(nextHop)
        guard !requireReachable || connected(hop) != nil else { throw EngineError("Next hop \(nextHop) is not in a connected IPv6 subnet") }
        let route = Route6(network: networkOf6(c.addr, c.prefix), prefix: c.prefix, nextHop: hop)
        statics.removeAll { $0.network == route.network && $0.prefix == route.prefix }
        statics.append(route)
    }

    func removeStatic(_ cidr: String) throws {
        let c = try parseCidr6(cidr)
        statics.removeAll { $0.network == networkOf6(c.addr, c.prefix) && $0.prefix == c.prefix }
    }

    /// `show ipv6 route` (spec M9 §6): the connected prefixes, the static routes, then the defaults from RAs still valid.
    func routes() -> [RouteRow] {
        var rows: [RouteRow] = []
        for i in node.interfaces where i.up {
            for a in i.v6?.addrs ?? [] where a.origin != .linkLocal && a.state != .duplicate {
                let row = RouteRow(dest: "\(formatIp6(networkOf6(a.addr, a.prefix)))/\(a.prefix)", nextHop: nil, iface: i.name, isStatic: false)
                if !rows.contains(row) { rows.append(row) }
            }
        }
        let statics = statics.map {
            RouteRow(dest: "\(formatIp6($0.network))/\($0.prefix)", nextHop: formatIp6($0.nextHop), iface: connected($0.nextHop)?.iface.name ?? "-", isStatic: true)
        }
        let learned = defaults.filter { $0.expiresAt > now }.map {
            RouteRow(dest: "::/0", nextHop: formatIp6($0.addr), iface: $0.iface.name, isStatic: false, ra: true)
        }
        return rows + statics + learned
    }

    /// The interface whose address prefix holds `addr`, longest prefix first; link-local and duplicate addresses do not count.
    private func connected(_ addr: UInt128) -> (iface: Interface, prefix: Int)? {
        var best: (iface: Interface, prefix: Int)?
        for i in node.interfaces where i.up {
            for a in i.v6?.addrs ?? [] where a.origin != .linkLocal && a.state != .duplicate && inSubnet6(addr, a.addr, a.prefix)
                && a.prefix > (best?.prefix ?? -1) {
                best = (i, a.prefix)
            }
        }
        return best
    }

    /// Hosts, and the Cloud, which never routes IPv6 (spec M9 §6), look for routers and learn their default route from RAs.
    private var actsAsHost: Bool { node is Host || node is Cloud }

    private func usableLinkLocal(_ iface: Interface) -> UInt128? {
        iface.v6?.addrs.first { $0.origin == .linkLocal && $0.state == .preferred }?.addr
    }

    /// IOS `ipv6 unicast-routing` on or off (spec M9 §5): on, every IPv6 interface advertises at once (from the scheduler); off,
    /// a last RA with lifetime 0 where RAs were sent.
    func setRouting(_ on: Bool) {
        guard on != routing else { return }
        routing = on
        for i in node.interfaces where i.v6 != nil {
            if on {
                i.v6!.raDue = arm(now)
            } else {
                if i.v6!.lastRa != nil { advertise(i, lifetime: 0) }
                i.v6!.raDue = nil
                i.v6!.lastRa = nil
            }
        }
    }

    /// A multicast RA with IOS defaults and the interface's global prefixes; the next one 200 s later (none after lifetime 0).
    private func advertise(_ iface: Interface, lifetime: UInt16 = RA_LIFETIME_S) {
        guard iface.lineUp, let ll = usableLinkLocal(iface) else {
            iface.v6?.raDue = nil
            return
        }
        let prefixes = iface.v6!.addrs.filter { $0.origin == .manual && $0.state != .duplicate }
            .map { PrefixInfo(prefix: networkOf6($0.addr, $0.prefix), length: $0.prefix) }
        sendNdp(.ra(RouterAdvert(lifetime: lifetime, slla: iface.mac, prefixes: prefixes)), src: ll, dst: ALL_NODES, on: iface)
        iface.v6!.lastRa = now
        iface.v6!.raDue = lifetime == 0 ? nil : arm(now + RA_INTERVAL_NS)
    }

    /// One RS to all routers; the next one after the current wait, which doubles up to 3600 s (RFC 7559).
    private func solicit(_ iface: Interface) {
        guard iface.lineUp, let ll = usableLinkLocal(iface) else {
            iface.v6?.rsDue = nil
            return
        }
        sendNdp(.rs(slla: iface.mac), src: ll, dst: ALL_ROUTERS, on: iface)
        iface.v6!.rsDue = arm(now + iface.v6!.rsInterval)
        iface.v6!.rsInterval = min(2 * iface.v6!.rsInterval, RS_MAX_INTERVAL_NS)
    }

    /// The link-local address passed DAD: a host looks for routers, a router that routes advertises.
    private func linkLocalReady(_ iface: Interface) {
        if actsAsHost {
            solicit(iface)
        } else if routing {
            advertise(iface)
        }
    }

    /// Starts DAD for every tentative address of `iface` not yet under way, if its line is up. The NS leaves from the scheduler,
    /// so a device switched off in the same instant sends nothing.
    private func dad(_ iface: Interface) {
        guard iface.lineUp, let addrs = iface.v6?.addrs else { return }
        for k in addrs.indices where addrs[k].state == .tentative && addrs[k].dadDue == nil {
            iface.v6!.addrs[k].dadDue = arm(now)
        }
    }

    /// Every address back to tentative, no timer running.
    private func rewind(_ iface: Interface) {
        guard iface.v6 != nil else { return }
        for k in iface.v6!.addrs.indices {
            iface.v6!.addrs[k].state = .tentative
            iface.v6!.addrs[k].dadDue = nil
            iface.v6!.addrs[k].probed = false
        }
        iface.v6!.rsDue = nil
        iface.v6!.rsInterval = RS_INTERVAL_NS
        iface.v6!.raDue = nil
        iface.v6!.lastRa = nil
    }

    /// The line came back up, or the device was switched on: DAD runs again on every address (spec M9 §5).
    private func restart(_ iface: Interface) {
        rewind(iface)
        iface.v6?.lineWasUp = iface.lineUp
        dad(iface)
    }

    /// Power on.
    func start() {
        for i in node.interfaces where i.v6 != nil { restart(i) }
    }

    /// Power off: what was learned is forgotten (SLAAC addresses, neighbours, default routers); every address waits for DAD again.
    func reset() {
        for i in node.interfaces where i.v6 != nil {
            i.v6!.addrs.removeAll { $0.origin == .slaac }
            rewind(i)
            i.v6!.lineWasUp = false
        }
        neighbors.reset()
        defaults = []
        hopLimit = HOP_LIMIT6
    }

    /// The cable at `phys` changed, or the device at its other end was switched: a line back up restarts its interfaces.
    func linkChanged(_ phys: Interface) {
        for i in node.interfaces where (i.dot1q?.parent ?? i) === phys && i.v6 != nil {
            if i.lineUp && !i.v6!.lineWasUp { restart(i) } else { i.v6!.lineWasUp = i.lineUp }
        }
    }

    private func arm(_ due: Int) -> Int {
        node.sim.sched.at(due) { [weak self] in self?.expire(due) }
        return due
    }

    private func expire(_ due: Int) {
        var ready: [Interface] = []
        for i in node.interfaces where i.v6 != nil {
            for k in i.v6!.addrs.indices where i.v6!.addrs[k].dadDue == due {
                let a = i.v6!.addrs[k]
                if !a.probed {
                    // RFC 4862 §5.4.2: one NS from the unspecified address to the solicited-node group, no link-layer address.
                    i.v6!.addrs[k].probed = true
                    i.v6!.addrs[k].dadDue = arm(due + ND_RETRANS_NS)
                    sendNdp(.ns(target: a.addr, slla: nil), src: 0, dst: solicitedNode(a.addr), on: i)
                } else if !i.lineUp {
                    // The line went down during DAD: the address stays tentative until it comes back and DAD starts over (spec M9 §5).
                    i.v6!.addrs[k].dadDue = nil
                    i.v6!.addrs[k].probed = false
                } else {
                    i.v6!.addrs[k].dadDue = nil
                    i.v6!.addrs[k].state = .preferred
                    if a.origin == .linkLocal { ready.append(i) }
                }
            }
            if i.v6!.rsDue == due { solicit(i) }
            if i.v6!.raDue == due { advertise(i) }
        }
        for i in ready { linkLocalReady(i) }
    }
}
