typealias IcmpListener = (Ipv4Packet, IcmpMessage) -> Void
/// `iface` is where the datagram came in; nil when the node sent it to itself.
typealias UdpHandler = (Ipv4Packet, UdpDatagram, Interface?) -> Void

/// A node with an IPv4 stack: ARP, routing, ICMP and UDP.
class IpNode: Node {
    private(set) lazy var arp = Arp(node: self)
    private(set) lazy var routes = RoutingTable(interfaces: { [unowned self] in self.interfaces })
    private(set) lazy var resolver = Resolver(node: self)
    private(set) lazy var tcp = Tcp(node: self)
    var defaultTtl: UInt8 = 64
    var forwarding = false
    /// Name server set by hand (resolv.conf); wins over the one learned from DHCP.
    var nameServer: UInt32?
    /// Name server from DHCP option 6.
    var learnedNameServer: UInt32?
    var dhcpServer: DhcpServer?
    var dnsServer: DnsServer?
    /// NAT/PAT (routers): translates between the inside interfaces and the outside one.
    var nat: Nat?
    /// Stateful firewall (routers).
    var firewall: Firewall?
    /// RIPv2 (routers), spec M8 §3.
    var rip: Rip?
    /// OSPFv2 in area 0 (routers), spec M8 §4.
    var ospf: Ospf?
    /// Turns the discard sink off again; nil while it is off.
    private var sinkStop: (() -> Void)?

    /// Discard service on TCP and UDP port 9: accepts connections and datagrams and drops the data.
    var sink: Bool { sinkStop != nil }

    var effectiveNameServer: UInt32? { nameServer ?? learnedNameServer }
    private var ipId: UInt16 = 0
    private var udp: [UInt16: UdpHandler] = [:]
    /// Ordered (not a dictionary): listener order must be deterministic.
    private var icmpListeners: [(token: Int, listener: IcmpListener)] = []
    private var nextToken = 0

    func setIp(_ ifName: String, _ cidr: String) throws {
        let iface = try self.iface(ifName)
        let c = try parseCidr(cidr)
        if c.prefix < 31 && (c.addr == networkOf(c.addr, c.prefix) || c.addr == broadcastOf(c.addr, c.prefix)) {
            throw EngineError("\(cidr) is a network or broadcast address")
        }
        for other in interfaces where other !== iface {
            if let o = other.ipv4, inSubnet(c.addr, o.addr, min(c.prefix, o.prefix)) {
                throw EngineError("\(cidr) overlaps with \(other.name)")
            }
        }
        // Typed addresses only: a DHCP lease is run-time state (the server checks its pool before offering).
        let typed = { (i: Interface) in (i.node as? Host)?.dhcp?.iface !== i }
        if let other = iface.segmentPeers().first(where: { $0.ipv4?.addr == c.addr && typed($0) }) {
            throw EngineError("Duplicate address: \(formatIp(c.addr)) is already used by \(other.node.name) \(other.name) on this segment")
        }
        iface.ipv4 = c
    }

    func setGateway(_ ip: String) throws {
        try routes.addStatic("0.0.0.0/0", ip)
    }

    func ownsIp(_ ip: UInt32) -> Bool {
        interfaces.contains { $0.ipv4?.addr == ip }
    }

    /// Source address this node would use to reach `dst`, if routable.
    func sourceFor(_ dst: UInt32) -> UInt32? {
        ownsIp(dst) ? dst : routes.lookup(dst)?.iface.ipv4?.addr
    }

    @discardableResult
    func bindUdp(_ port: UInt16, _ handler: @escaping UdpHandler) throws -> () -> Void {
        guard udp[port] == nil else { throw EngineError("UDP port \(port) already in use") }
        udp[port] = handler
        return { [weak self] in self?.udp[port] = nil }
    }

    @discardableResult
    func onIcmp(_ listener: @escaping IcmpListener) -> () -> Void {
        nextToken += 1
        let token = nextToken
        icmpListeners.append((token, listener))
        return { [weak self] in self?.icmpListeners.removeAll { $0.token == token } }
    }

    func configureSink(_ on: Bool) throws {
        guard on != sink else { return }
        guard on else {
            sinkStop?()
            sinkStop = nil
            return
        }
        try tcp.listen(PORT_DISCARD)
        let unbind: () -> Void
        do {
            unbind = try bindUdp(PORT_DISCARD) { [unowned self] _, u, _ in
                if case .traffic(let d) = u.payload { self.sim.flows[d.flow]?(d) }
            }
        } catch {
            tcp.unlisten(PORT_DISCARD)
            throw error
        }
        sinkStop = { [unowned self] in
            unbind()
            self.tcp.unlisten(PORT_DISCARD)
        }
    }

    /// RIP on or reconfigured, or off with nil (spec M8 §2). Off, it forgets what it learned and says nothing (IOS `no router rip`).
    func configureRip(_ config: RipConfig?) throws {
        guard let config else {
            rip?.stop()
            rip = nil
            return
        }
        for name in config.interfaces { _ = try iface(name) }
        if let bad = config.passive.first(where: { !config.interfaces.contains($0) }) {
            throw EngineError("\(bad) is passive but does not take part in RIP")
        }
        if let rip {
            rip.reconfigure(config)
        } else {
            let started = Rip(node: self, config: config)
            rip = started
            if powered { started.start() }
        }
    }

    /// OSPF on or reconfigured, or off with nil (spec M8 §2, §4). Off, it forgets everything and says nothing.
    func configureOspf(_ config: OspfConfig?) throws {
        guard let config else {
            ospf?.stop()
            ospf = nil
            return
        }
        for c in config.interfaces {
            _ = try iface(c.name)
            guard (0...255).contains(c.priority) else { throw EngineError("OSPF priority must be between 0 and 255") }
        }
        if let text = config.routerId {
            guard let id = try? parseIp(text), id != 0 else { throw EngineError("Invalid router ID: \"\(text)\"") }
        } else if !interfaces.contains(where: { $0.ipv4 != nil }) {
            throw EngineError("\(name) needs an IPv4 address or a router ID for OSPF")
        }
        if let ospf {
            ospf.reconfigure(config)
        } else {
            let started = Ospf(node: self, config: config)
            ospf = started
            if powered { started.start() }
        }
    }

    override func reset() {
        arp.reset()
        resolver.reset()
        dhcpServer?.reset()
        tcp.reset()
        nat?.reset()
        firewall?.reset()
        rip?.stop()
        ospf?.stop()
    }

    /// Originates a packet (from `src` if given, else the outgoing interface's address). Returns false when there is no route to `dst`.
    @discardableResult
    func sendPacket(_ dst: UInt32, _ payload: L4, ttl: UInt8? = nil, src: UInt32? = nil) -> Bool {
        guard let from = sourceFor(dst) else { return false }
        output(makeIpv4(src: src ?? from, dst: dst, ttl: ttl ?? defaultTtl, id: nextIpId(), payload: payload))
        return true
    }

    @discardableResult
    func sendUdp(_ dst: UInt32, srcPort: UInt16, dstPort: UInt16, data: [UInt8], ttl: UInt8? = nil) -> Bool {
        sendUdp(dst, srcPort: srcPort, dstPort: dstPort, payload: .raw(data), ttl: ttl)
    }

    @discardableResult
    func sendUdp(_ dst: UInt32, srcPort: UInt16, dstPort: UInt16, payload: UdpPayload, ttl: UInt8? = nil) -> Bool {
        sendPacket(dst, .udp(makeUdp(srcPort: srcPort, dstPort: dstPort, payload: payload)), ttl: ttl)
    }

    /// Limited broadcast (255.255.255.255) straight out of one interface, without routing: DHCP before the node has an address.
    func broadcast(on iface: Interface, src: UInt32, _ payload: L4) {
        sendFrame(iface, to: BROADCAST_MAC, etherType: ETHERTYPE_IPV4,
                  .ipv4(makeIpv4(src: src, dst: BROADCAST_IP, ttl: defaultTtl, id: nextIpId(), payload: payload)))
    }

    /// Link-local multicast (224.0.0.0/24, TTL 1, never forwarded) straight out of one interface: routing protocol packets (spec M8 §2).
    func multicast(on iface: Interface, src: UInt32, group: UInt32, mac: Mac, _ payload: L4) {
        sendFrame(iface, to: mac, etherType: ETHERTYPE_IPV4, .ipv4(makeIpv4(src: src, dst: group, ttl: 1, id: nextIpId(), payload: payload)))
    }

    func sendFrame(_ iface: Interface, to dst: Mac, etherType: UInt16, _ payload: L3) {
        iface.send(EthernetFrame(id: sim.nextId(), src: iface.mac, dst: dst, etherType: etherType, payload: payload))
    }

    /// Sends an ICMP error about `orig` back to its source (never about ICMP errors).
    func icmpError(_ orig: Ipv4Packet, type: UInt8, code: UInt8) {
        // About a packet NAT already translated: quote it, and answer, as the inside host sent it.
        let orig = nat?.untranslated(orig) ?? orig
        if case .icmp(let m) = orig.payload, m.type != ICMP_ECHO_REQUEST && m.type != ICMP_ECHO_REPLY { return }
        if orig.dst == BROADCAST_IP || orig.src == 0 { return }
        // About a packet for this node: from the address it hit (Linux; traceroute's last hop); otherwise from the way back.
        guard let src = ownsIp(orig.dst) ? orig.dst : sourceFor(orig.src) else { return }
        let quote = serializeHeader(orig) + serializeL4(orig).prefix(8)
        output(makeIpv4(src: src, dst: orig.src, ttl: defaultTtl, id: nextIpId(),
                        payload: .icmp(makeIcmp(type: type, code: code, id: 0, seq: 0, data: quote))))
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        // The RIP-2 and OSPF groups only reach a router running that protocol, as if it had joined them.
        let group = (frame.dst == RIP_MAC && rip != nil) || ((frame.dst == OSPF_ALL_ROUTERS_MAC || frame.dst == OSPF_ALL_DROUTERS_MAC) && ospf != nil)
        guard frame.dst == iface.mac || frame.dst == BROADCAST_MAC || group else { return }
        // 802.1Q, after the NIC's MAC filter: a tagged frame belongs to the subinterface for its VLAN; a host, or a router without one, drops it.
        var to = iface
        if let vlan = frame.vlan {
            guard let sub = interfaces.first(where: { $0.dot1q?.parent === iface && $0.dot1q?.vlan == vlan }) else {
                sim.emit(.drop, node: id, iface: iface.name, frame: frame, reason: .unknownVlan)
                return
            }
            to = sub
        }
        switch frame.payload {
        case .arp(let a): arp.handle(a, on: to)
        case .ipv4(let p): input(p, on: to)
        case .bpdu: break // never reached: the MAC filter above already left out the PVST+ group address
        }
    }

    private func input(_ p: Ipv4Packet, on iface: Interface) {
        // Netfilter order: NAT outside → inside, then routing and filtering (here for the router itself, in `output` for forwarded
        // packets), then NAT inside → outside.
        let packet = nat?.inbound(p, on: iface) ?? p
        let subnetBroadcast = iface.ipv4.map { packet.dst == broadcastOf($0.addr, $0.prefix) } ?? false
        if ownsIp(packet.dst) || packet.dst == BROADCAST_IP || subnetBroadcast || [RIP_GROUP, OSPF_ALL_ROUTERS, OSPF_ALL_DROUTERS].contains(packet.dst) {
            guard firewall?.admits(packet, from: iface, to: nil) ?? true else { return }
            return deliver(packet, from: iface)
        }
        guard forwarding else { return }
        if packet.ttl <= 1 {
            sim.emit(.drop, node: id, iface: iface.name, packet: packet, reason: .ttlExpired)
            return icmpError(packet, type: ICMP_TIME_EXCEEDED, code: 0)
        }
        output(withTtl(packet, packet.ttl - 1), from: iface)
    }

    /// Routes and sends a packet; `inIface` is where a forwarded one came in (nil: this node originated it).
    private func output(_ p: Ipv4Packet, from inIface: Interface? = nil) {
        if ownsIp(p.dst) {
            sim.sched.after(0) { [self] in deliver(p, from: nil) }
            return
        }
        guard let hop = routes.lookup(p.dst) else {
            sim.emit(.drop, node: id, packet: p, reason: .noRoute)
            return icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_NET)
        }
        if let inIface, let firewall, !firewall.admits(p, from: inIface, to: hop.iface) { return }
        if inIface == nil { firewall?.track(p) }
        // Checked before NAT, so "fragmentation needed" goes back to the inside host, not to our own outside address.
        if p.size > hop.iface.mtu {
            // ponytail: no IPv4 fragmentation; non-DF oversize packets are dropped
            sim.emit(.drop, node: id, iface: hop.iface.name, packet: p, reason: .mtuExceeded)
            if p.dontFragment { icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_FRAG_NEEDED) }
            return
        }
        arp.send(hop.iface, nextHop: hop.nextHop, inIface.flatMap { nat?.outbound(p, from: $0, to: hop.iface) } ?? p)
    }

    private func deliver(_ p: Ipv4Packet, from iface: Interface?) {
        switch p.payload {
        case .icmp(let m):
            if m.type == ICMP_ECHO_REQUEST && p.dst != BROADCAST_IP {
                // Reply from the address that was pinged, like Linux and IOS do.
                output(makeIpv4(src: p.dst, dst: p.src, ttl: defaultTtl, id: nextIpId(),
                                payload: .icmp(makeIcmp(type: ICMP_ECHO_REPLY, code: 0, id: m.id, seq: m.seq, data: m.data))))
            }
            for entry in icmpListeners { entry.listener(p, m) }
        case .udp(let u):
            if let handler = udp[u.dstPort] {
                handler(p, u, iface)
            } else if p.dst != BROADCAST_IP {
                icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_PORT)
            }
        case .tcp(let t):
            tcp.input(p, t)
        case .ospf(let o):
            if let iface { ospf?.receive(p, o, on: iface) }
        }
    }

    private func nextIpId() -> UInt16 {
        ipId &+= 1
        return ipId
    }
}
