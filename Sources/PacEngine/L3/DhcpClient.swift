enum DhcpState: String {
    case initial = "INIT", selecting = "SELECTING", requesting = "REQUESTING", bound = "BOUND", renewing = "RENEWING", rebinding = "REBINDING"
}

/// RFC 2131 §4.1 retransmission: 4 s doubling up to 64 s.
private let DHCP_RETRY_NS = [4, 8, 16, 32, 64].map { $0 * S }
/// REQUESTs sent for one offer before starting over.
private let DHCP_REQUEST_TRIES = 4
/// RFC 2131 §4.4.5: RENEWING/REBINDING retransmit after half the time left, at least 60 s.
private let DHCP_MIN_RETRY_NS = 60 * S

/// RFC 2131 client on one interface: DORA, renewal at T1 (unicast), rebinding at T2 (broadcast), expiry.
/// It stores no timers (retain cycles): a callback acts only if `generation` is unchanged since it was scheduled.
// ponytail: no INIT-REBOOT, no ARP probe/DECLINE, no randomised backoff; a power cycle starts over with a DISCOVER
final class DhcpClient {
    unowned let node: IpNode
    unowned let iface: Interface
    private(set) var state = DhcpState.initial
    private(set) var server: UInt32?
    private(set) var leaseS = 0
    /// When the REQUEST that got the current lease was sent: T1, T2 and expiry count from here (RFC 2131 §4.4.1),
    /// so the client always gives up a little before the server does.
    private(set) var leaseStart = 0
    private var requestedAt = 0
    private var xid: UInt32 = 0
    private var offered: UInt32 = 0
    private var tries = 0
    private var generation = 0
    private var unbind: () -> Void = {}

    init(node: IpNode, iface: Interface) throws {
        self.node = node
        self.iface = iface
        unbind = try node.bindUdp(PORT_DHCP_CLIENT) { [weak self] _, u, _ in
            if case .dhcp(let m) = u.payload { self?.receive(m) }
        }
    }

    var t1: Int { leaseStart + leaseS * S / 2 }
    var t2: Int { leaseStart + leaseS * S * 7 / 8 }
    var expiry: Int { leaseStart + leaseS * S }
    var hasLease: Bool { state == .bound || state == .renewing || state == .rebinding }

    /// INIT → SELECTING: drops any lease and broadcasts a DISCOVER on the next event.
    func start() {
        generation += 1
        clear()
        state = .selecting
        xid = node.sim.rng.uint32()
        tries = 0
        later(0) { $0.discover() }
    }

    /// Stops the client and removes what it configured; with `release`, gives a held lease back first (RFC 2131 §4.4.6).
    func stop(release: Bool) {
        if release, hasLease, let server, let ip = iface.ipv4?.addr {
            node.sendUdp(server, srcPort: PORT_DHCP_CLIENT, dstPort: PORT_DHCP_SERVER, payload: .dhcp(DhcpMessage(
                op: 1, xid: node.sim.rng.uint32(), broadcast: false, ciaddr: ip, chaddr: iface.mac, type: .release, serverId: server)))
        }
        generation += 1
        clear()
    }

    /// Leaves DHCP mode for good.
    func shutdown() {
        stop(release: true)
        unbind()
    }

    /// `ipconfig /renew`: a client holding a lease renews it now by unicast; otherwise it starts over.
    func renewNow() {
        guard hasLease else { return start() }
        enterRenewing()
    }

    private func later(_ delay: Int, _ action: @escaping (DhcpClient) -> Void) {
        let gen = generation
        node.sim.sched.after(delay) { [self] in
            if gen == generation { action(self) }
        }
    }

    private func clear() {
        if hasLease { iface.ipv4 = nil }
        node.routes.dhcpGateway = nil
        node.learnedNameServer = nil
        server = nil
        leaseS = 0
        state = .initial
    }

    private func broadcast(_ m: DhcpMessage, from src: UInt32) {
        node.broadcast(on: iface, src: src, .udp(makeUdp(srcPort: PORT_DHCP_CLIENT, dstPort: PORT_DHCP_SERVER, payload: .dhcp(m))))
    }

    private func retryDelay() -> Int {
        defer { tries += 1 }
        return DHCP_RETRY_NS[min(tries, DHCP_RETRY_NS.count - 1)]
    }

    private func discover() {
        broadcast(DhcpMessage(op: 1, xid: xid, broadcast: true, chaddr: iface.mac, type: .discover), from: 0)
        later(retryDelay()) { $0.discover() }
    }

    private func requestOffer() {
        guard tries < DHCP_REQUEST_TRIES else { return start() }
        requestedAt = node.sim.now
        broadcast(DhcpMessage(op: 1, xid: xid, broadcast: true, chaddr: iface.mac, type: .request, requestedIp: offered, serverId: server), from: 0)
        later(retryDelay()) { $0.requestOffer() }
    }

    private func receive(_ m: DhcpMessage) {
        guard m.op == 2, m.xid == xid, m.chaddr == iface.mac else { return }
        switch (state, m.type) {
        case (.selecting, .offer):
            guard let chosen = m.serverId else { return }
            generation += 1
            offered = m.yiaddr
            server = chosen
            state = .requesting
            tries = 0
            requestOffer()
        case (.requesting, .ack), (.renewing, .ack), (.rebinding, .ack):
            bind(m)
        case (.requesting, .nak), (.renewing, .nak), (.rebinding, .nak):
            start()
        default:
            break
        }
    }

    private func bind(_ m: DhcpMessage) {
        generation += 1
        // ponytail: a server omitting option 1 gives a /24, not the classful default
        iface.ipv4 = Cidr(addr: m.yiaddr, prefix: (m.subnetMask ?? 0xFFFF_FF00).nonzeroBitCount)
        node.routes.dhcpGateway = m.router
        node.learnedNameServer = m.dns
        server = m.serverId ?? server
        leaseS = Int(m.leaseS ?? UInt32(DHCP_LEASE_DEFAULT_S))
        leaseStart = requestedAt
        state = .bound
        let now = node.sim.now
        later(t1 - now) { $0.enterRenewing() }
        later(t2 - now) { $0.enterRebinding() }
        later(expiry - now) { $0.start() }
    }

    private func enterRenewing() {
        state = .renewing
        xid = node.sim.rng.uint32()
        renew()
    }

    private func renew() {
        guard let server, let ip = iface.ipv4?.addr else { return }
        requestedAt = node.sim.now
        node.sendUdp(server, srcPort: PORT_DHCP_CLIENT, dstPort: PORT_DHCP_SERVER,
                     payload: .dhcp(DhcpMessage(op: 1, xid: xid, broadcast: false, ciaddr: ip, chaddr: iface.mac, type: .request)))
        retry(before: t2) { if $0.state == .renewing { $0.renew() } }
    }

    private func enterRebinding() {
        state = .rebinding
        xid = node.sim.rng.uint32()
        rebind()
    }

    private func rebind() {
        guard let ip = iface.ipv4?.addr else { return }
        requestedAt = node.sim.now
        broadcast(DhcpMessage(op: 1, xid: xid, broadcast: false, ciaddr: ip, chaddr: iface.mac, type: .request), from: ip)
        retry(before: expiry) { if $0.state == .rebinding { $0.rebind() } }
    }

    private func retry(before deadline: Int, _ action: @escaping (DhcpClient) -> Void) {
        let wait = max((deadline - node.sim.now) / 2, DHCP_MIN_RETRY_NS)
        if node.sim.now + wait < deadline { later(wait, action) }
    }
}
