import Foundation

/// A rule's address: "any" (both versions), or an IPv4 or IPv6 address (/32, /128) or prefix (spec M9 §10).
private enum Match {
    case any
    case v4(Cidr)
    case v6(Cidr6)
}

private func holds(_ m: Match, _ a: UInt32) -> Bool {
    switch m {
    case .any: true
    case .v4(let c): inSubnet(a, c.addr, c.prefix)
    case .v6: false
    }
}

private func holds(_ m: Match, _ a: UInt128) -> Bool {
    switch m {
    case .any: true
    case .v4: false
    case .v6(let c): inSubnet6(a, c.addr, c.prefix)
    }
}

/// A rule as matched: "any" matches both versions, an address only its own.
private struct CompiledRule {
    let iface: String
    let out: Bool
    let allow: Bool
    /// The IPv4 protocol number; ICMP also matches ICMPv6 (spec M9 §10).
    let proto: UInt8?
    let src: Match
    let dst: Match
    let port: UInt16?

    func matches(_ p: Ipv4Packet, _ e: Endpoints<UInt32>?) -> Bool {
        (proto.map { $0 == p.proto } ?? true) && holds(src, p.src) && holds(dst, p.dst)
            && (port.map { $0 == e?.dstPort } ?? true)
    }

    func matches(_ p: Ipv6Packet, _ e: Endpoints<UInt128>?) -> Bool {
        (proto.map { ($0 == IPPROTO_ICMP ? IPPROTO_ICMPV6 : $0) == p.payload.nextHeader } ?? true) && holds(src, p.src) && holds(dst, p.dst)
            && (port.map { $0 == e?.dstPort } ?? true)
    }

    /// The rule's interface is the packet's ingress (`in`) or egress (`out`).
    func on(_ inIface: Interface, _ outIface: Interface?) -> Bool {
        iface == (out ? outIface?.name : inIface.name)
    }
}

private func parseMatch(_ text: String) throws -> Match {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.lowercased() == "any" { return .any }
    if t.contains(":") { return .v6(t.contains("/") ? try parseCidr6(t) : Cidr6(addr: try parseIp6(t), prefix: 128)) }
    return .v4(t.contains("/") ? try parseCidr(t) : Cidr(addr: try parseIp(t), prefix: 32))
}

private func compile(_ r: FirewallRule, on node: IpNode) throws -> CompiledRule {
    _ = try node.iface(r.iface)
    if let port = r.port {
        guard r.proto == .tcp || r.proto == .udp else { throw EngineError("A port needs TCP or UDP") }
        guard (1...65535).contains(port) else { throw EngineError("Port must be between 1 and 65535") }
    }
    let proto: UInt8? = switch r.proto {
    case .any: nil
    case .icmp: IPPROTO_ICMP
    case .tcp: IPPROTO_TCP
    case .udp: IPPROTO_UDP
    }
    let (src, dst) = (try parseMatch(r.src), try parseMatch(r.dst))
    switch (src, dst) {
    case (.v4, .v6), (.v6, .v4): throw EngineError("A rule cannot mix IPv4 and IPv6 addresses")
    default: break
    }
    return CompiledRule(iface: r.iface, out: r.direction == .outbound, allow: r.action == .allow, proto: proto,
                        src: src, dst: dst, port: r.port.map { UInt16($0) })
}

/// Stateful packet filter on a router (spec §5.4), one decision per packet in netfilter order: after NAT outside → inside, before
/// NAT inside → outside, so rules see inside addresses. A packet let through records its flow; the flow's later packets in either
/// direction, and ICMP errors quoting it, pass without rules (iptables ESTABLISHED/RELATED). Otherwise the first rule whose
/// interface is the packet's ingress (`in`) or egress (`out`) decides, then the default policy. Router-originated packets are never checked,
/// but their flows are recorded so the replies get back (Linux conntrack tracks OUTPUT even with no OUTPUT rules).
/// IPv6 is filtered the same way with its own flows (spec M9 §10), except NS and NA, which always pass.
// ponytail: flows idle out like NAT translations (no TCP state machine); linear scans
final class Firewall {
    unowned let node: IpNode
    let config: FirewallConfig
    private let rules: [CompiledRule]
    /// Flows let through, as their first packet went, with their idle deadline.
    private var flows: [(flow: Endpoints<UInt32>, expiresAt: Int)] = []
    /// The same for IPv6.
    private var flows6: [(flow: Endpoints<UInt128>, expiresAt: Int)] = []

    init(node: IpNode, config: FirewallConfig) throws {
        rules = try config.rules.map { try compile($0, on: node) }
        self.node = node
        self.config = config
    }

    /// Power cycle: tracked flows are forgotten; the rules stay.
    func reset() {
        flows = []
        flows6 = []
    }

    /// A packet forwarded from `inIface` to `outIface`, or for the router itself (`outIface` nil). A refused one is logged as a drop.
    func admits(_ p: Ipv4Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
        let e = endpoints(p)
        let quoted: Endpoints<UInt32>? = if case .icmp(let m) = p.payload { quotedEndpoints(m) } else { nil }
        return decide(e, quoted, in: &flows, rules.first { $0.matches(p, e) && $0.on(inIface, outIface) }, inIface, outIface) {
            node.sim.emit(.drop, node: node.id, iface: $0.name, packet: p, reason: $1)
        }
    }

    /// The same decision for IPv6, except that NS and NA always pass, like IOS's implicit `permit icmp any any nd-ns` and `nd-na`:
    /// address resolution never breaks (spec M9 §10).
    func admits(_ p: Ipv6Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
        if case .ndp(let n) = p.payload, n.type == ND_NS || n.type == ND_NA { return true }
        let e = endpoints(p)
        let quoted: Endpoints<UInt128>? = if case .icmp(let m) = p.payload { quotedEndpoints6(m) } else { nil }
        return decide(e, quoted, in: &flows6, rules.first { $0.matches(p, e) && $0.on(inIface, outIface) }, inIface, outIface) {
            node.sim.emit(.drop, node: node.id, iface: $0.name, reason: $1, packet6: p)
        }
    }

    /// A packet the router originates: never filtered, its flow recorded or refreshed.
    func track(_ p: Ipv4Packet) {
        guard let e = endpoints(p), !refreshed(e, in: &flows) else { return }
        flows.append((e, node.sim.now + flowTimeout(e.proto)))
    }

    /// The same for IPv6.
    func track(_ p: Ipv6Packet) {
        guard let e = endpoints(p), !refreshed(e, in: &flows6) else { return }
        flows6.append((e, node.sim.now + flowTimeout(e.proto)))
    }

    /// A tracked flow, or an ICMP error quoting one, passes; otherwise `rule` decides, then the policy. A packet let through records
    /// its flow; a refused one goes to `drop` with the interface the rule names.
    private func decide<A: Equatable>(_ e: Endpoints<A>?, _ quoted: Endpoints<A>?, in flows: inout [(flow: Endpoints<A>, expiresAt: Int)],
                                      _ rule: CompiledRule?, _ inIface: Interface, _ outIface: Interface?,
                                      drop: (Interface, DropReason) -> Void) -> Bool {
        if refreshed(e, in: &flows) { return true }
        if let quoted, flows.contains(where: { $0.flow == quoted || $0.flow == quoted.reversed }) { return true }
        guard rule?.allow ?? (config.defaultAction == .allow) else {
            drop(rule?.out == true ? outIface ?? inIface : inIface, rule == nil ? .firewallDefault : .firewallRule)
            return false
        }
        if let e { flows.append((e, node.sim.now + flowTimeout(e.proto))) }
        return true
    }

    /// Forgets idle flows, then refreshes `e`'s in either direction; false when it is not tracked.
    private func refreshed<A: Equatable>(_ e: Endpoints<A>?, in flows: inout [(flow: Endpoints<A>, expiresAt: Int)]) -> Bool {
        let now = node.sim.now
        flows.removeAll { $0.expiresAt <= now }
        guard let e, let i = flows.firstIndex(where: { $0.flow == e || $0.flow == e.reversed }) else { return false }
        flows[i].expiresAt = now + flowTimeout(e.proto)
        return true
    }
}
