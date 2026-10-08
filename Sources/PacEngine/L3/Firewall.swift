import Foundation

/// A rule as matched: "any" is 0.0.0.0/0, an address /32.
private struct CompiledRule {
    let iface: String
    let out: Bool
    let allow: Bool
    let proto: UInt8?
    let src: Cidr
    let dst: Cidr
    let port: UInt16?

    func matches(_ p: Ipv4Packet, _ e: Endpoints?) -> Bool {
        (proto.map { $0 == p.proto } ?? true) && inSubnet(p.src, src.addr, src.prefix) && inSubnet(p.dst, dst.addr, dst.prefix)
            && (port.map { $0 == e?.dstPort } ?? true)
    }
}

private func parseMatch(_ text: String) throws -> Cidr {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.lowercased() == "any" { return Cidr(addr: 0, prefix: 0) }
    return t.contains("/") ? try parseCidr(t) : Cidr(addr: try parseIp(t), prefix: 32)
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
    return CompiledRule(iface: r.iface, out: r.direction == .outbound, allow: r.action == .allow, proto: proto,
                        src: try parseMatch(r.src), dst: try parseMatch(r.dst), port: r.port.map { UInt16($0) })
}

/// Stateful packet filter on a router (spec §5.4), one decision per packet in netfilter order: after NAT outside → inside, before
/// NAT inside → outside, so rules see inside addresses. A packet let through records its flow; the flow's later packets in either
/// direction, and ICMP errors quoting it, pass without rules (iptables ESTABLISHED/RELATED). Otherwise the first rule whose
/// interface is the packet's ingress (`in`) or egress (`out`) decides, then the default policy. Router-originated packets are never checked.
// ponytail: flows idle out like NAT translations (no TCP state machine); linear scans
final class Firewall {
    unowned let node: IpNode
    let config: FirewallConfig
    private let rules: [CompiledRule]
    /// Flows let through, as their first packet went, with their idle deadline.
    private var flows: [(flow: Endpoints, expiresAt: Int)] = []

    init(node: IpNode, config: FirewallConfig) throws {
        rules = try config.rules.map { try compile($0, on: node) }
        self.node = node
        self.config = config
    }

    /// Power cycle: tracked flows are forgotten; the rules stay.
    func reset() {
        flows = []
    }

    /// A packet forwarded from `inIface` to `outIface`, or for the router itself (`outIface` nil). A refused one is logged as a drop.
    func admits(_ p: Ipv4Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
        let now = node.sim.now
        flows.removeAll { $0.expiresAt <= now }
        let e = endpoints(p)
        if let e, let i = flows.firstIndex(where: { $0.flow == e || $0.flow == e.reversed }) {
            flows[i].expiresAt = now + flowTimeout(e.proto)
            return true
        }
        if case .icmp(let m) = p.payload, let q = quotedEndpoints(m), flows.contains(where: { $0.flow == q || $0.flow == q.reversed }) {
            return true
        }
        let rule = rules.first { $0.matches(p, e) && $0.iface == ($0.out ? outIface?.name : inIface.name) }
        guard rule?.allow ?? (config.defaultAction == .allow) else {
            let at = rule?.out == true ? outIface ?? inIface : inIface
            node.sim.emit(.drop, node: node.id, iface: at.name, packet: p, reason: rule == nil ? .firewallDefault : .firewallRule)
            return false
        }
        if let e { flows.append((e, now + flowTimeout(e.proto))) }
        return true
    }
}
