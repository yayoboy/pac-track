let ARP_CACHE_NS = 300 * S
let ARP_RETRY_NS = 1 * S
let ARP_RETRIES = 3
let ARP_PENDING_MAX = 3

struct ArpEntry: Equatable {
    let ip: UInt32
    let mac: Mac
    let iface: String
    let expiresAt: Int
}

private final class Pending {
    let iface: Interface
    var packets: [Ipv4Packet]
    var tries = 0

    init(iface: Interface, packets: [Ipv4Packet]) {
        self.iface = iface
        self.packets = packets
    }
}

final class Arp {
    unowned let node: IpNode
    private var cache: [UInt32: (mac: Mac, iface: Interface, expiresAt: Int)] = [:]
    private var pending: [UInt32: Pending] = [:]

    init(node: IpNode) {
        self.node = node
    }

    func lookup(_ ip: UInt32) -> Mac? {
        guard let entry = cache[ip] else { return nil }
        if node.sim.now >= entry.expiresAt {
            cache[ip] = nil
            return nil
        }
        return entry.mac
    }

    func entries() -> [ArpEntry] {
        cache.filter { node.sim.now < $0.value.expiresAt }
            .map { ArpEntry(ip: $0.key, mac: $0.value.mac, iface: $0.value.iface.name, expiresAt: $0.value.expiresAt) }
            .sorted { $0.ip < $1.ip }
    }

    /// Empties the cache and abandons pending resolutions (their retry timers find nothing pending and stop).
    func reset() {
        cache = [:]
        pending = [:]
    }

    /// Sends `packet` to `nextHop` on `iface`, resolving its MAC first if needed.
    func send(_ iface: Interface, nextHop: UInt32, _ packet: Ipv4Packet) {
        if let mac = lookup(nextHop) {
            return node.sendFrame(iface, to: mac, etherType: ETHERTYPE_IPV4, .ipv4(packet))
        }
        if let waiting = pending[nextHop] {
            if waiting.packets.count < ARP_PENDING_MAX {
                waiting.packets.append(packet)
            } else {
                node.sim.emit(.drop, node: node.id, iface: iface.name, packet: packet, reason: .arpPendingFull)
            }
            return
        }
        let fresh = Pending(iface: iface, packets: [packet])
        pending[nextHop] = fresh
        request(nextHop, fresh)
    }

    func handle(_ arp: ArpPacket, on iface: Interface) {
        let own = iface.ipv4?.addr
        let forUs = own != nil && arp.targetIp == own
        let known = cache[arp.senderIp] != nil
        // A reply to our own pending request counts even if our address changed meanwhile (a DHCP RELEASE sent as the lease is dropped).
        let awaited = arp.op == 2 && pending[arp.senderIp] != nil
        if forUs || known || awaited { cache[arp.senderIp] = (arp.senderMac, iface, node.sim.now + ARP_CACHE_NS) }
        if forUs, arp.op == 1, let own {
            node.sendFrame(iface, to: arp.senderMac, etherType: ETHERTYPE_ARP,
                           .arp(ArpPacket(op: 2, senderMac: iface.mac, senderIp: own, targetMac: arp.senderMac, targetIp: arp.senderIp)))
        }
        if forUs || known || awaited, let waiting = pending.removeValue(forKey: arp.senderIp) {
            for p in waiting.packets { node.sendFrame(waiting.iface, to: arp.senderMac, etherType: ETHERTYPE_IPV4, .ipv4(p)) }
        }
    }

    private func request(_ ip: UInt32, _ p: Pending) {
        p.tries += 1
        node.sendFrame(p.iface, to: BROADCAST_MAC, etherType: ETHERTYPE_ARP,
                       .arp(ArpPacket(op: 1, senderMac: p.iface.mac, senderIp: p.iface.ipv4?.addr ?? 0, targetMac: "00:00:00:00:00:00", targetIp: ip)))
        // No stored timer (it would retain `p` in a cycle): a resolved request is simply no longer pending.
        node.sim.sched.after(ARP_RETRY_NS) { [self] in
            guard pending[ip] === p else { return }
            if p.tries < ARP_RETRIES { return request(ip, p) }
            pending[ip] = nil
            for packet in p.packets {
                node.sim.emit(.drop, node: node.id, iface: p.iface.name, packet: packet, reason: .arpTimeout)
                node.icmpError(packet, type: ICMP_DEST_UNREACH, code: UNREACH_HOST)
            }
        }
    }
}
