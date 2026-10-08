import Foundation

let DHCP_LEASE_DEFAULT_S = 86_400
let DHCP_LEASE_RANGE_S = 10...31_536_000
/// How long an offered address stays reserved for the client's REQUEST.
let DHCP_OFFER_HOLD_NS = 60 * S
/// Conflict detection: how long the server waits for an echo reply before offering an address (IOS `ip dhcp ping timeout` 500 ms).
let DHCP_PROBE_WAIT_NS = 500 * MS
/// ICMP id of the server's probe pings.
private let DHCP_PROBE_ID: UInt16 = 0xDC

struct DhcpPool: Equatable {
    var start: UInt32
    var end: UInt32
    var excluded: [ClosedRange<UInt32>]
    var gateway: UInt32?
    var dns: UInt32?
    var leaseS: Int

    /// Canonical text form, as the snapshot and the project file show it.
    var config: DhcpConfig {
        DhcpConfig(start: formatIp(start), end: formatIp(end),
                   excluded: excluded.map { $0.lowerBound == $0.upperBound ? formatIp($0.lowerBound) : "\(formatIp($0.lowerBound))-\(formatIp($0.upperBound))" },
                   gateway: gateway.map(formatIp), dns: dns.map(formatIp), leaseS: leaseS)
    }
}

struct DhcpLease: Equatable {
    let ip: UInt32
    let mac: Mac
    var expiresAt: Int
    /// False while only offered.
    var bound: Bool
}

private func optionalIp(_ s: String?) throws -> UInt32? {
    guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    return try parseIp(t)
}

/// Parses and checks a server configuration. `requireInSubnet: false` restores a saved pool whose subnet changed since (the server then stays silent).
func parseDhcpPool(_ c: DhcpConfig, on node: IpNode, requireInSubnet: Bool = true) throws -> DhcpPool {
    let start = try parseIp(c.start.trimmingCharacters(in: .whitespaces))
    let end = try parseIp(c.end.trimmingCharacters(in: .whitespaces))
    guard start <= end else { throw EngineError("DHCP pool start \(formatIp(start)) is after its end \(formatIp(end))") }
    let excluded = try c.excluded.map { item -> ClosedRange<UInt32> in
        let parts = item.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let lo = try? parseIp(parts[0]), let hi = try? parseIp(parts[parts.count - 1]), lo <= hi else {
            throw EngineError("Invalid excluded range: \"\(item)\"")
        }
        return lo...hi
    }
    let gateway = try optionalIp(c.gateway)
    let dns = try optionalIp(c.dns)
    guard DHCP_LEASE_RANGE_S.contains(c.leaseS) else { throw EngineError("Lease time must be between 10 s and 365 days") }
    if requireInSubnet {
        guard let net = node.interfaces.lazy.compactMap(\.ipv4).first(where: { inSubnet(start, $0.addr, $0.prefix) && inSubnet(end, $0.addr, $0.prefix) }),
              net.prefix >= 31 || (start > networkOf(net.addr, net.prefix) && end < broadcastOf(net.addr, net.prefix)) else {
            throw EngineError("DHCP pool \(formatIp(start))-\(formatIp(end)) is outside the subnets of \(node.name)")
        }
        if let gateway, !inSubnet(gateway, net.addr, net.prefix) {
            throw EngineError("Gateway \(formatIp(gateway)) is outside the pool's subnet \(formatIp(networkOf(net.addr, net.prefix)))/\(net.prefix)")
        }
    }
    return DhcpPool(start: start, end: end, excluded: excluded, gateway: gateway, dns: dns, leaseS: c.leaseS)
}

/// A pool proposal for the subnet of `cidr` (.100–.199 when it fits, else the upper half); nil for /31 and /32.
public func suggestedDhcpConfig(cidr: String) -> DhcpConfig? {
    guard let c = try? parseCidr(cidr), c.prefix <= 30 else { return nil }
    let net = networkOf(c.addr, c.prefix)
    let hosts = broadcastOf(c.addr, c.prefix) - net - 1
    let (start, end) = hosts >= 200 ? (net + 100, net + 199) : (net + 1 + hosts / 2, net + hosts)
    return DhcpConfig(start: formatIp(start), end: formatIp(end))
}

/// RFC 2131 server for one pool, answering on the interface whose subnet holds the pool. Without relay agents a
/// pool serves only its own segment: routers never forward the clients' limited broadcasts.
/// Like IOS, it pings a new address before offering it and never offers one that answers.
// ponytail: one probe echo (IOS sends two); conflicts are not shown in the UI, a power cycle clears them (`clear ip dhcp conflict`)
final class DhcpServer {
    unowned let node: IpNode
    var pool: DhcpPool
    /// Ordered by address.
    private var leases: [DhcpLease] = []
    /// Addresses that answered a probe (IOS `show ip dhcp conflict`), in detection order.
    private(set) var conflicts: [UInt32] = []
    private var unbind: () -> Void = {}
    private var unlisten: () -> Void = {}

    init(node: IpNode, pool: DhcpPool) throws {
        self.node = node
        self.pool = pool
        unbind = try node.bindUdp(PORT_DHCP_SERVER) { [weak self] _, u, iface in
            if case .dhcp(let m) = u.payload, let iface { self?.receive(m, on: iface) }
        }
        unlisten = node.onIcmp { [weak self] p, m in
            guard let self, m.type == ICMP_ECHO_REPLY, m.id == DHCP_PROBE_ID, !conflicts.contains(p.src),
                  leases.contains(where: { $0.ip == p.src && !$0.bound }) else { return }
            conflicts.append(p.src)
        }
    }

    /// Live bindings and offers, by address.
    func view() -> [DhcpLease] {
        leases.filter { $0.expiresAt > node.sim.now }
    }

    /// Power cycle: bindings live in RAM, as on IOS.
    func reset() {
        leases = []
        conflicts = []
    }

    func stop() {
        unbind()
        unlisten()
    }

    private func receive(_ m: DhcpMessage, on iface: Interface) {
        guard m.op == 1, let own = iface.ipv4, inSubnet(pool.start, own.addr, own.prefix), inSubnet(pool.end, own.addr, own.prefix) else { return }
        leases.removeAll { $0.expiresAt <= node.sim.now }
        switch m.type {
        case .discover: offer(m, iface, own)
        case .request: request(m, iface, own)
        case .release: leases.removeAll { $0.mac == m.chaddr && $0.ip == m.ciaddr }
        default: break
        }
    }

    private func available(_ ip: UInt32, for mac: Mac) -> Bool {
        (pool.start...pool.end).contains(ip) && !pool.excluded.contains { $0.contains(ip) } && ip != pool.gateway && ip != pool.dns
            && !node.ownsIp(ip) && !conflicts.contains(ip) && !leases.contains { $0.ip == ip && $0.mac != mac }
    }

    /// The client's current address, else the one it asks for, else the lowest free one.
    private func pick(for mac: Mac, requested: UInt32?) -> UInt32? {
        if let held = leases.first(where: { $0.mac == mac }), available(held.ip, for: mac) { return held.ip }
        if let requested, available(requested, for: mac) { return requested }
        var ip = pool.start
        while true {
            if let range = pool.excluded.first(where: { $0.contains(ip) }) {
                guard range.upperBound < pool.end else { return nil }
                ip = range.upperBound + 1
                continue
            }
            if available(ip, for: mac) { return ip }
            guard ip < pool.end else { return nil }
            ip += 1
        }
    }

    private func record(_ ip: UInt32, _ mac: Mac, until: Int, bound: Bool) {
        leases.removeAll { $0.mac == mac || $0.ip == ip }
        leases.append(DhcpLease(ip: ip, mac: mac, expiresAt: until, bound: bound))
        leases.sort { $0.ip < $1.ip }
    }

    private func offer(_ m: DhcpMessage, _ iface: Interface, _ own: Cidr) {
        // ponytail: an exhausted pool stays silent (IOS only logs it)
        guard let ip = pick(for: m.chaddr, requested: m.requestedIp) else { return }
        let known = leases.contains { $0.mac == m.chaddr && $0.ip == ip }
        if !leases.contains(where: { $0.mac == m.chaddr && $0.ip == ip && $0.bound }) {
            record(ip, m.chaddr, until: node.sim.now + DHCP_OFFER_HOLD_NS, bound: false)
        }
        // An address already offered to or bound by this client was probed then.
        guard !known else { return reply(.offer, to: m, yiaddr: ip, iface, own) }
        node.sendPacket(ip, .icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: DHCP_PROBE_ID, seq: 0, data: [])))
        node.sim.sched.after(DHCP_PROBE_WAIT_NS) { [weak self] in
            // A power cycle or a REQUEST meanwhile dropped the held offer: nothing to do.
            guard let self, leases.contains(where: { $0.mac == m.chaddr && $0.ip == ip && !$0.bound }) else { return }
            guard conflicts.contains(ip) else { return reply(.offer, to: m, yiaddr: ip, iface, own) }
            leases.removeAll { $0.ip == ip }
            offer(m, iface, own)
        }
    }

    private func request(_ m: DhcpMessage, _ iface: Interface, _ own: Cidr) {
        if let chosen = m.serverId, chosen != own.addr {
            leases.removeAll { $0.mac == m.chaddr && !$0.bound } // the client took another server's offer
            return
        }
        let ip = m.requestedIp ?? m.ciaddr
        guard ip != 0 else { return }
        guard available(ip, for: m.chaddr) else { return reply(.nak, to: m, yiaddr: 0, iface, own) }
        record(ip, m.chaddr, until: node.sim.now + pool.leaseS * S, bound: true)
        reply(.ack, to: m, yiaddr: ip, iface, own)
    }

    private func reply(_ type: DhcpType, to m: DhcpMessage, yiaddr: UInt32, _ iface: Interface, _ own: Cidr) {
        let positive = type != .nak
        let msg = DhcpMessage(op: 2, xid: m.xid, broadcast: m.broadcast, ciaddr: positive ? m.ciaddr : 0, yiaddr: yiaddr, chaddr: m.chaddr, type: type,
                              leaseS: positive ? UInt32(pool.leaseS) : nil, serverId: own.addr,
                              subnetMask: positive ? prefixMask(own.prefix) : nil,
                              router: positive ? pool.gateway : nil, dns: positive ? pool.dns : nil)
        let payload = L4.udp(makeUdp(srcPort: PORT_DHCP_SERVER, dstPort: PORT_DHCP_CLIENT, payload: .dhcp(msg)))
        // RFC 2131 §4.1 without relays: a client that has an address gets a unicast, otherwise a broadcast (Pac-Track clients
        // set the broadcast flag, so the unicast-to-chaddr case never arises). NAKs are always broadcast.
        if positive && m.ciaddr != 0 {
            node.sendPacket(m.ciaddr, payload)
        } else {
            node.broadcast(on: iface, src: own.addr, payload)
        }
    }
}

extension IpNode {
    /// Turns the DHCP server on, updates its pool (keeping the bindings) or turns it off with nil.
    func configureDhcpServer(_ c: DhcpConfig?, requireInSubnet: Bool = true) throws {
        guard let c else {
            dhcpServer?.stop()
            dhcpServer = nil
            return
        }
        let pool = try parseDhcpPool(c, on: self, requireInSubnet: requireInSubnet)
        if let server = dhcpServer {
            server.pool = pool
        } else {
            dhcpServer = try DhcpServer(node: self, pool: pool)
        }
    }
}
