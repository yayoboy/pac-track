typealias IcmpListener = (Ipv4Packet, IcmpMessage) -> Void
/// `iface` is where the datagram came in; nil when the node sent it to itself.
typealias UdpHandler = (Ipv4Packet, UdpDatagram, Interface?) -> Void

/// A node with an IPv4 stack: ARP, routing, ICMP and UDP.
class IpNode: Node {
    private(set) lazy var arp = Arp(node: self)
    private(set) lazy var routes = RoutingTable(interfaces: { [unowned self] in self.interfaces })
    var defaultTtl: UInt8 = 64
    var forwarding = false
    /// Name server set by hand (resolv.conf); wins over the one learned from DHCP.
    var nameServer: UInt32?
    /// Name server from DHCP option 6.
    var learnedNameServer: UInt32?
    var dhcpServer: DhcpServer?

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

    override func reset() {
        arp.reset()
        dhcpServer?.reset()
    }

    /// Originates a packet. Returns false when there is no route to `dst`.
    @discardableResult
    func sendPacket(_ dst: UInt32, _ payload: L4, ttl: UInt8? = nil) -> Bool {
        guard let src = sourceFor(dst) else { return false }
        output(makeIpv4(src: src, dst: dst, ttl: ttl ?? defaultTtl, id: nextIpId(), payload: payload))
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

    func sendFrame(_ iface: Interface, to dst: Mac, etherType: UInt16, _ payload: L3) {
        iface.send(EthernetFrame(id: sim.nextId(), src: iface.mac, dst: dst, etherType: etherType, payload: payload))
    }

    /// Sends an ICMP error about `orig` back to its source (never about ICMP errors).
    func icmpError(_ orig: Ipv4Packet, type: UInt8, code: UInt8) {
        if case .icmp(let m) = orig.payload, m.type != ICMP_ECHO_REQUEST && m.type != ICMP_ECHO_REPLY { return }
        if orig.dst == BROADCAST_IP || orig.src == 0 { return }
        guard let src = sourceFor(orig.src) else { return }
        let quote = serializeHeader(orig) + serializeL4(orig).prefix(8)
        output(makeIpv4(src: src, dst: orig.src, ttl: defaultTtl, id: nextIpId(),
                        payload: .icmp(makeIcmp(type: type, code: code, id: 0, seq: 0, data: quote))))
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        guard frame.dst == iface.mac || frame.dst == BROADCAST_MAC else { return }
        switch frame.payload {
        case .arp(let a): arp.handle(a, on: iface)
        case .ipv4(let p): input(p, on: iface)
        }
    }

    private func input(_ p: Ipv4Packet, on iface: Interface) {
        let subnetBroadcast = iface.ipv4.map { p.dst == broadcastOf($0.addr, $0.prefix) } ?? false
        if ownsIp(p.dst) || p.dst == BROADCAST_IP || subnetBroadcast { return deliver(p, from: iface) }
        guard forwarding else { return }
        if p.ttl <= 1 {
            sim.emit(.drop, node: id, iface: iface.name, packet: p, reason: .ttlExpired)
            return icmpError(p, type: ICMP_TIME_EXCEEDED, code: 0)
        }
        output(withTtl(p, p.ttl - 1))
    }

    private func output(_ p: Ipv4Packet) {
        if ownsIp(p.dst) {
            sim.sched.after(0) { [self] in deliver(p, from: nil) }
            return
        }
        guard let hop = routes.lookup(p.dst) else {
            sim.emit(.drop, node: id, packet: p, reason: .noRoute)
            return icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_NET)
        }
        if p.size > hop.iface.mtu {
            // ponytail: no IPv4 fragmentation; non-DF oversize packets are dropped
            sim.emit(.drop, node: id, iface: hop.iface.name, packet: p, reason: .mtuExceeded)
            if p.dontFragment { icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_FRAG_NEEDED) }
            return
        }
        arp.send(hop.iface, nextHop: hop.nextHop, p)
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
        }
    }

    private func nextIpId() -> UInt16 {
        ipId &+= 1
        return ipId
    }
}
