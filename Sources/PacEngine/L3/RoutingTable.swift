struct NextHop {
    let iface: Interface
    let nextHop: UInt32
}

struct RouteView: Equatable {
    let isStatic: Bool
    let network: UInt32
    let prefix: Int
    let nextHop: UInt32?
    let iface: String
    /// Default route learned from DHCP.
    var dhcp = false
    /// Hops of a route learned by RIP (distance 120); nil for the others.
    var metric: Int? = nil
}

private struct StaticRoute {
    let network: UInt32
    let prefix: Int
    let nextHop: UInt32
}

/// A route a routing protocol installed (RIP: administrative distance 120, spec M8 §2).
struct LearnedRoute {
    let network: UInt32
    let prefix: Int
    let nextHop: UInt32
    let iface: Interface
    let metric: Int
}

final class RoutingTable {
    private var statics: [StaticRoute] = []
    /// Default gateway learned from DHCP (option 3). A static default route wins over it, as IOS gives DHCP routes distance 254.
    var dhcpGateway: UInt32?
    /// Set by RIP; a connected or static route for the same prefix wins (lower administrative distance).
    var learned: [LearnedRoute] = []
    private let interfaces: () -> [Interface]

    init(interfaces: @escaping () -> [Interface]) {
        self.interfaces = interfaces
    }

    /// `requireReachable: false` restores saved routes whose next hop is currently unreachable (kept inactive, like IOS).
    func addStatic(_ cidr: String, _ nextHop: String, requireReachable: Bool = true) throws {
        let c = try parseCidr(cidr)
        let route = StaticRoute(network: networkOf(c.addr, c.prefix), prefix: c.prefix, nextHop: try parseIp(nextHop))
        guard !requireReachable || interfaces().contains(where: { i in i.ipv4.map { inSubnet(route.nextHop, $0.addr, $0.prefix) } ?? false }) else {
            throw EngineError("Next hop \(nextHop) is not in a connected subnet")
        }
        statics.removeAll { $0.network == route.network && $0.prefix == route.prefix }
        statics.append(route)
    }

    func removeStatic(_ cidr: String) throws {
        let c = try parseCidr(cidr)
        let network = networkOf(c.addr, c.prefix)
        statics.removeAll { $0.network == network && $0.prefix == c.prefix }
    }

    /// A connected route, or a static one whose next hop is reachable, for exactly this prefix: a learned route for it is not used,
    /// shown or advertised (spec M8 §2).
    func shadows(_ network: UInt32, _ prefix: Int) -> Bool {
        statics.contains { $0.network == network && $0.prefix == prefix && connectedFor($0.nextHop) != nil }
            || interfaces().contains { i in i.up && i.ipv4.map { networkOf($0.addr, $0.prefix) == network && $0.prefix == prefix } ?? false }
    }

    func view() -> [RouteView] {
        let connected = interfaces().compactMap { i -> RouteView? in
            guard i.up, let c = i.ipv4 else { return nil }
            return RouteView(isStatic: false, network: networkOf(c.addr, c.prefix), prefix: c.prefix, nextHop: nil, iface: i.name)
        }
        let statics = statics.map {
            RouteView(isStatic: true, network: $0.network, prefix: $0.prefix, nextHop: $0.nextHop, iface: connectedFor($0.nextHop)?.iface.name ?? "-")
        }
        let rip = learned.filter { !shadows($0.network, $0.prefix) }.map {
            RouteView(isStatic: false, network: $0.network, prefix: $0.prefix, nextHop: $0.nextHop, iface: $0.iface.name, metric: $0.metric)
        }
        let learned = dhcpGateway.map {
            [RouteView(isStatic: false, network: 0, prefix: 0, nextHop: $0, iface: connectedFor($0)?.iface.name ?? "-", dhcp: true)]
        } ?? []
        return connected + statics + rip + learned
    }

    /// Longest-prefix match; on equal length the lower administrative distance wins: connected, static, RIP, DHCP default.
    /// Static routes whose next hop is not currently reachable are skipped (as if withdrawn from the RIB).
    func lookup(_ dst: UInt32) -> NextHop? {
        let conn = connectedFor(dst)
        var best: NextHop?
        var bestPrefix = -1
        for r in statics where inSubnet(dst, r.network, r.prefix) && r.prefix > bestPrefix {
            guard let via = connectedFor(r.nextHop) else { continue }
            best = NextHop(iface: via.iface, nextHop: r.nextHop)
            bestPrefix = r.prefix
        }
        for r in learned where inSubnet(dst, r.network, r.prefix) && r.prefix > bestPrefix {
            best = NextHop(iface: r.iface, nextHop: r.nextHop)
            bestPrefix = r.prefix
        }
        if best == nil, let gw = dhcpGateway, let via = connectedFor(gw) {
            best = NextHop(iface: via.iface, nextHop: gw)
            bestPrefix = 0
        }
        if let conn, conn.prefix >= bestPrefix { return NextHop(iface: conn.iface, nextHop: dst) }
        return best
    }

    private func connectedFor(_ ip: UInt32) -> (iface: Interface, prefix: Int)? {
        var best: (iface: Interface, prefix: Int)?
        for i in interfaces() {
            guard i.up, let c = i.ipv4, inSubnet(ip, c.addr, c.prefix), c.prefix > (best?.prefix ?? -1) else { continue }
            best = (i, c.prefix)
        }
        return best
    }
}
