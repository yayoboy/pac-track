import Foundation

/// RFC 4861 RetransTimer (IOS `ipv6 nd ns-interval` 1000 ms): DAD waits this long for an answer (spec M9 §5).
let ND_RETRANS_NS = 1 * S
/// Hop limit of the packets a host or router originates (Linux and IOS default, spec M9 §3).
let HOP_LIMIT6: UInt8 = 64

enum AddrOrigin: Sendable {
    case linkLocal, manual, slaac
}

enum DadState: Sendable {
    case tentative, preferred, duplicate
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
}

/// The IPv6 stack of a host or router (spec M9), idle until an interface turns IPv6 on. Timers are deadlines checked in `expire`,
/// as in `Rip`: an expiry does nothing if its deadline was moved or cleared since.
final class Ipv6 {
    unowned let node: IpNode
    var hopLimit = HOP_LIMIT6

    init(node: IpNode) {
        self.node = node
    }

    private var now: Int { node.sim.now }

    /// IPv6 on with these settings, or off with nil (spec M9 §2). A new address starts tentative; DAD runs when the line is up.
    func configure(_ name: String, _ config: Ipv6Config?) throws {
        let iface = try node.iface(name)
        guard let config else {
            iface.v6 = nil
            return
        }
        let manual = try config.address.map { try manualAddress($0, on: iface) }
        var v6 = iface.v6 ?? Ipv6Iface(config: config, addrs: [Addr6(addr: linkLocal(iface.mac), prefix: 64, origin: .linkLocal)], lineWasUp: iface.lineUp)
        v6.config = config
        v6.addrs.removeAll { $0.origin == .manual && ($0.addr != manual?.addr || $0.prefix != manual?.prefix) }
        if let manual, !v6.addrs.contains(where: { $0.origin == .manual }) {
            v6.addrs.append(Addr6(addr: manual.addr, prefix: manual.prefix, origin: .manual))
        }
        iface.v6 = v6
        dad(iface)
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

    /// The groups an interface has joined: all-nodes, and each address's solicited-node group.
    private func groups(_ i: Interface) -> [UInt128] {
        guard let v6 = i.v6 else { return [] }
        return [ALL_NODES] + v6.addrs.map { solicitedNode($0.addr) }
    }

    /// A packet that reached an interface: for a group it joined or an address in use, else ignored.
    func input(_ p: Ipv6Packet, on iface: Interface) {
        guard iface.v6 != nil else { return } // IPv6 off: like an unknown EtherType
        if isMulticast6(p.dst) {
            if groups(iface).contains(p.dst) { deliver(p, on: iface) }
            return
        }
        if owns(p.dst) { deliver(p, on: iface) }
    }

    private func deliver(_ p: Ipv6Packet, on iface: Interface) {
        switch p.payload {
        case .ndp(let n): receive(n, p, on: iface)
        case .icmp, .udp: break
        }
    }

    /// NDP, only from the link itself (hop limit 255, RFC 4861 §6.1, §7.1): DAD (RFC 4862 §5.4.3–5.4.4).
    private func receive(_ n: NdpMessage, _ p: Ipv6Packet, on iface: Interface) {
        guard p.hopLimit == 255 else { return }
        switch n.body {
        case .ns(let target, _):
            guard let k = iface.v6!.addrs.firstIndex(where: { $0.addr == target }) else { return }
            switch iface.v6!.addrs[k].state {
            case .tentative:
                if p.src == 0 { duplicate(iface, k) } // another node's DAD for the same address
            case .duplicate:
                break
            case .preferred:
                // Another node's DAD for an address in use here: the answer goes to every node (RFC 4861 §7.2.4).
                if p.src == 0 {
                    sendNdp(.na(target: target, router: false, solicited: false, override: true, tlla: iface.mac), src: target, dst: ALL_NODES, on: iface)
                }
            }
        case .na(let target, _, _, _, _):
            if let k = iface.v6!.addrs.firstIndex(where: { $0.addr == target }), iface.v6!.addrs[k].state == .tentative { duplicate(iface, k) }
        case .rs, .ra:
            break
        }
    }

    /// DAD failed: the address is never used (spec M9 §5).
    private func duplicate(_ iface: Interface, _ k: Int) {
        iface.v6!.addrs[k].state = .duplicate
        iface.v6!.addrs[k].dadDue = nil
        node.sim.emit(.state, node: node.id, iface: iface.name, note: "DAD: \(formatIp6(iface.v6!.addrs[k].addr)) duplicato", proto: .ndp)
    }

    private func sendNdp(_ body: NdpBody, src: UInt128, dst: UInt128, on iface: Interface) {
        let p = makeIpv6(src: src, dst: dst, hopLimit: 255, payload: .ndp(NdpMessage(body: body)))
        node.sendFrame(iface, to: multicastMac6(dst), etherType: ETHERTYPE_IPV6, .ipv6(p))
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

    /// Power off: what was learned is forgotten, every address waits for DAD again.
    func reset() {
        for i in node.interfaces where i.v6 != nil {
            rewind(i)
            i.v6!.lineWasUp = false
        }
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
        for i in node.interfaces where i.v6 != nil {
            for k in i.v6!.addrs.indices where i.v6!.addrs[k].dadDue == due {
                let a = i.v6!.addrs[k]
                if !a.probed {
                    // RFC 4862 §5.4.2: one NS from the unspecified address to the solicited-node group, no link-layer address.
                    i.v6!.addrs[k].probed = true
                    i.v6!.addrs[k].dadDue = arm(due + ND_RETRANS_NS)
                    sendNdp(.ns(target: a.addr, slla: nil), src: 0, dst: solicitedNode(a.addr), on: i)
                } else {
                    i.v6!.addrs[k].dadDue = nil
                    i.v6!.addrs[k].state = .preferred
                }
            }
        }
    }
}
