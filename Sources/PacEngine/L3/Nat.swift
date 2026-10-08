/// Idle timeouts (spec §5.4, IOS defaults): TCP 2 h 4 min (RFC 5382 REQ-5), UDP 5 min (RFC 4787 REQ-5), ICMP 60 s (RFC 5508's minimum).
let NAT_TCP_TIMEOUT = 7440 * S
let NAT_UDP_TIMEOUT = 300 * S
let NAT_ICMP_TIMEOUT = 60 * S
/// IOS `ip nat translation finrst-timeout`: a TCP translation lasts this long once a FIN or RST went by.
let NAT_FINRST_TIMEOUT = 60 * S

/// Idle timeout of a translation or a firewall flow.
func flowTimeout(_ proto: UInt8, closing: Bool = false) -> Int {
    switch proto {
    case IPPROTO_TCP: closing ? NAT_FINRST_TIMEOUT : NAT_TCP_TIMEOUT
    case IPPROTO_UDP: NAT_UDP_TIMEOUT
    default: NAT_ICMP_TIMEOUT
    }
}

/// One translation, an IOS "extended" entry: inside local ↔ inside global for one remote endpoint.
/// For ICMP echo the ports are the identifier and the remote port is 0.
struct NatEntry: Equatable {
    let proto: UInt8
    let local: UInt32
    let localPort: UInt16
    let global: UInt32
    let globalPort: UInt16
    let remote: UInt32
    let remotePort: UInt16
    var expiresAt: Int
    /// A FIN or RST went by.
    var closing = false
}

/// RFC 3022 NAPT on a router, IOS `ip nat inside source list … interface <outside> overload`: TCP, UDP and echo requests from an
/// inside interface routed out of the outside one take the outside address. Endpoint-independent mapping (RFC 4787 REQ-1),
/// address-and-port-dependent filtering (only an entry's remote endpoint gets back in). Unmatched packets to the outside
/// address are the router's own.
// ponytail: linear scans and lazy expiry (no timers); fine for lab-sized tables
final class Nat {
    unowned let node: IpNode
    let config: NatConfig
    private var entries: [NatEntry] = []

    init(node: IpNode, config: NatConfig) throws {
        for name in config.inside + [config.outside].compactMap({ $0 }) { _ = try node.iface(name) }
        if let outside = config.outside, config.inside.contains(outside) {
            throw EngineError("\(outside) cannot be both inside and outside")
        }
        self.node = node
        self.config = config
    }

    private var now: Int { node.sim.now }

    /// Translations are bound to this address: a new one clears them, like IOS does when the interface address changes.
    private var outsideAddr: UInt32? {
        node.interfaces.first { $0.name == config.outside }?.ipv4?.addr
    }

    /// Live translations, oldest first.
    func view() -> [NatEntry] {
        let global = outsideAddr
        return entries.filter { $0.expiresAt > now && $0.global == global }
    }

    /// Power cycle (`clear ip nat translation *`); the configuration stays.
    func reset() {
        entries = []
    }

    /// Inside → outside, after routing (RFC 3022 §2.2).
    func outbound(_ p: Ipv4Packet, from inIface: Interface, to outIface: Interface) -> Ipv4Packet {
        guard config.inside.contains(inIface.name), outIface.name == config.outside, let global = outIface.ipv4?.addr else { return p }
        expire()
        if case .icmp(let m) = p.payload, let q = quotedEndpoints(m), q.proto != IPPROTO_ICMP {
            // An inside host's error about a translated reply, quoted as it was delivered (remote → local), leaves with the
            // global endpoint in both headers (RFC 5508 §4.2). An error never refreshes the entry.
            guard let e = entries.first(where: {
                $0.proto == q.proto && $0.remote == q.src && $0.remotePort == q.srcPort && $0.local == q.dst && $0.localPort == q.dstPort
            }) else { return p }
            var fixed = p
            fixed.payload = .icmp(withQuotedEndpoint(m, e.global, e.globalPort, destination: true))
            return rewritten(fixed, src: e.global)
        }
        // ponytail: echo replies from inside hosts leave untranslated (they only answer echo requests routed in untranslated)
        guard let e = endpoints(p) else { return p }
        if case .icmp(let m) = p.payload, m.type == ICMP_ECHO_REPLY { return p }
        let i = entries.firstIndex {
            $0.proto == e.proto && $0.local == e.src && $0.localPort == e.srcPort && $0.remote == e.dst && $0.remotePort == e.dstPort
        } ?? add(e, global: global)
        refresh(i, p)
        return rewritten(p, src: entries[i].global, srcPort: entries[i].globalPort)
    }

    /// Outside → inside, before routing: a reply to a translation, or an ICMP error about one (with its quoted packet,
    /// RFC 5508 §4), gets the inside address back. nil when nothing matches.
    func inbound(_ p: Ipv4Packet, on iface: Interface) -> Ipv4Packet? {
        guard iface.name == config.outside else { return nil }
        expire()
        if case .icmp(let m) = p.payload, let q = quotedEndpoints(m) {
            // The quote is our translated packet as it left (global → remote). An error never refreshes the entry.
            guard let e = entries.first(where: {
                $0.proto == q.proto && $0.global == q.src && $0.globalPort == q.srcPort && $0.remote == q.dst && $0.remotePort == q.dstPort
            }), p.dst == e.global else { return nil }
            var fixed = p
            fixed.payload = .icmp(withQuotedEndpoint(m, e.local, e.localPort))
            return rewritten(fixed, dst: e.local)
        }
        guard let e = endpoints(p), let i = entries.firstIndex(where: {
            $0.proto == e.proto && $0.global == e.dst && $0.globalPort == e.dstPort && $0.remote == e.src && $0.remotePort == e.srcPort
        }) else { return nil }
        refresh(i, p)
        return rewritten(p, dst: entries[i].local, dstPort: entries[i].localPort)
    }

    /// A packet this router already translated outbound, with its inside source back (Linux conntrack), so an error the router
    /// itself raises about it (an ARP timeout on the outside) reaches the inside host. nil when no translation matches.
    func untranslated(_ p: Ipv4Packet) -> Ipv4Packet? {
        expire()
        guard let e = endpoints(p), let entry = entries.first(where: {
            $0.proto == e.proto && $0.global == e.src && $0.globalPort == e.srcPort && $0.remote == e.dst && $0.remotePort == e.dstPort
        }) else { return nil }
        return rewritten(p, src: entry.local, srcPort: entry.localPort)
    }

    /// RFC 4787 REQ-1: a mapped inside endpoint keeps its global port for every remote; a new one keeps its own port if free
    /// (IOS, Linux), else takes the next free one above it, wrapping to 1024.
    private func add(_ e: Endpoints, global: UInt32) -> Int {
        let same = { (n: NatEntry) in n.proto == e.proto && n.global == global }
        let mapped = entries.first { same($0) && $0.local == e.src && $0.localPort == e.srcPort }?.globalPort
        var port = mapped ?? e.srcPort
        if mapped == nil {
            // ponytail: 64 512 ports per protocol are never exhausted in a lab; no exhaustion handling
            while entries.contains(where: { same($0) && $0.globalPort == port }) { port = port == .max ? 1024 : port + 1 }
        }
        entries.append(NatEntry(proto: e.proto, local: e.src, localPort: e.srcPort, global: global, globalPort: port,
                                remote: e.dst, remotePort: e.dstPort, expiresAt: now))
        return entries.count - 1
    }

    private func refresh(_ i: Int, _ p: Ipv4Packet) {
        if case .tcp(let t) = p.payload, !t.flags.isDisjoint(with: [.fin, .rst]) { entries[i].closing = true }
        entries[i].expiresAt = now + flowTimeout(entries[i].proto, closing: entries[i].closing)
    }

    private func expire() {
        let global = outsideAddr
        entries.removeAll { $0.expiresAt <= now || $0.global != global }
    }
}
