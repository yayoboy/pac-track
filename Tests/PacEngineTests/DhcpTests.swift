import Testing
@testable import PacEngine

private func ip(_ s: String) -> UInt32 { try! parseIp(s) }

private let pool = DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", gateway: "10.0.0.1", dns: "10.0.0.53", leaseS: 3600)

/// DHCP server S (10.0.0.1/24) cabled straight to client C: a 342-byte DHCP frame takes
/// 366 wire bytes × 8 at 1 Gb/s = 2 928 ns + 500 ns propagation = 3 428 ns.
private func direct(_ config: DhcpConfig = pool) throws -> (sim: Sim, srv: Host, pc: Host) {
    let sim = Sim()
    let srv = Host(sim: sim, id: "S")
    let pc = Host(sim: sim, id: "C")
    _ = try Link(sim: sim, try pc.iface("eth0"), try srv.iface("eth0"))
    try srv.setIp("eth0", "10.0.0.1/24")
    try srv.configureDhcpServer(config)
    return (sim, srv, pc)
}

/// DHCP messages put on a wire, in order: "<node> <type> <src>→<dst>".
private func dhcpTx(_ sim: Sim) -> [String] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, case .ipv4(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .dhcp(let m) = u.payload else { return nil }
        return "\(e.node) \(m.type.name) \(formatIp(p.src))→\(formatIp(p.dst))"
    }
}

/// REQUESTs client C put on the wire: "<ms> <dst>".
private func clientRequests(_ sim: Sim) -> [String] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == "C", case .ipv4(let p)? = e.frame?.payload, case .udp(let u) = p.payload,
              case .dhcp(let m) = u.payload, m.type == .request else { return nil }
        return "\(e.time / MS) \(formatIp(p.dst))"
    }
}

@Suite struct DhcpTests {
    @Test func runsDoraAndBindsTheFirstFreeAddressWithGatewayAndDns() throws {
        let (sim, srv, pc) = try direct()
        try pc.setDhcp(true)
        sim.run(1 * S)
        #expect(dhcpTx(sim) == [
            "C Discover 0.0.0.0→255.255.255.255",
            "S Offer 10.0.0.1→255.255.255.255",
            "C Request 0.0.0.0→255.255.255.255",
            "S ACK 10.0.0.1→255.255.255.255",
        ])
        let client = try #require(pc.dhcp)
        #expect(client.state == .bound)
        // the REQUEST left after DISCOVER + the 500 ms probe of 10.0.0.100 + OFFER (2 × 3 428 ns); bound 6 856 ns later
        #expect(client.leaseStart == 500_006_856)
        #expect(try pc.iface("eth0").ipv4 == Cidr(addr: ip("10.0.0.100"), prefix: 24))
        #expect(pc.routes.lookup(ip("8.8.8.8"))?.nextHop == ip("10.0.0.1"))
        #expect(pc.routes.view().last == RouteView(isStatic: false, network: 0, prefix: 0, nextHop: ip("10.0.0.1"), iface: "eth0", dhcp: true))
        #expect(pc.learnedNameServer == ip("10.0.0.53"))
        #expect(srv.dhcpServer?.view() == [DhcpLease(ip: ip("10.0.0.100"), mac: try pc.iface("eth0").mac, expiresAt: 500_010_284 + 3600 * S, bound: true)])
    }

    @Test func skipsExcludedAddressesServesClientsInOrderAndStaysSilentWhenThePoolIsFull() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW")
        for i in 1...4 { try sw.setSwitchport("Gi0/\(i)", PortConfig(portfast: true)) } // hosts on edge ports: forwarding once cabled
        let srv = Host(sim: sim, id: "S")
        _ = try Link(sim: sim, try srv.iface("eth0"), try sw.iface("Gi0/1"))
        try srv.setIp("eth0", "10.0.0.1/24")
        try srv.configureDhcpServer(DhcpConfig(start: "10.0.0.100", end: "10.0.0.102", excluded: ["10.0.0.100"]))
        let pcs = try (1...3).map { i -> Host in
            let pc = Host(sim: sim, id: "PC\(i)")
            _ = try Link(sim: sim, try pc.iface("eth0"), try sw.iface("Gi0/\(i + 1)"))
            try pc.setDhcp(true)
            return pc
        }
        sim.run(1 * S)
        #expect(pcs.map { $0.interfaces[0].ipv4.map { formatIp($0.addr) } } == ["10.0.0.101", "10.0.0.102", nil])
        #expect(pcs[2].dhcp?.state == .selecting)
        #expect(srv.dhcpServer?.view().map { formatIp($0.ip) } == ["10.0.0.101", "10.0.0.102"])
    }

    @Test func renewsByUnicastAtT1AndExtendsTheLease() throws {
        var config = pool
        config.leaseS = 60
        let (sim, srv, pc) = try direct(config)
        try pc.setDhcp(true)
        let t1 = 500_006_856 + 30 * S
        sim.sched.runUntil(t1 - 1)
        #expect(pc.dhcp?.state == .bound)
        sim.sched.runUntil(t1 + 1 * MS)
        // The REQUEST is sent at T1 and the lease counts from then. No ARP wait: the client learnt the server's MAC when the
        // server's probe ARP for 10.0.0.100 was retried (1 s) after the client had taken that address.
        #expect(pc.dhcp?.leaseStart == t1)
        #expect(try pc.iface("eth0").ipv4 != nil)
        #expect(pc.dhcp?.state == .bound)
        #expect(Array(dhcpTx(sim).suffix(2)) == ["C Request 10.0.0.100→10.0.0.1", "S ACK 10.0.0.1→10.0.0.100"])
        // The server counts from its ACK: after the REQUEST (3 428 ns)
        #expect(srv.dhcpServer?.view().first?.expiresAt == t1 + 3_428 + 60 * S)
    }

    @Test func rebindsAtT2AndDropsTheAddressWhenTheLeaseExpires() throws {
        var config = pool
        config.leaseS = 60
        let (sim, srv, pc) = try direct(config)
        try pc.setDhcp(true)
        sim.run(1 * S)
        srv.powered = false
        srv.reset()
        let expiry = 500_006_856 + 60 * S
        sim.sched.runUntil(expiry - 1)
        #expect(pc.dhcp?.state == .rebinding)
        #expect(try pc.iface("eth0").ipv4?.addr == ip("10.0.0.100"))
        // The T1 unicast never left (ARP to a dead server); at T2 (53 s) a broadcast REQUEST; no retry fits before expiry.
        #expect(Array(dhcpTx(sim).suffix(2)) == ["S ACK 10.0.0.1→255.255.255.255", "C Request 10.0.0.100→255.255.255.255"])
        sim.sched.runUntil(expiry)
        #expect(try pc.iface("eth0").ipv4 == nil)
        #expect(pc.routes.lookup(ip("8.8.8.8")) == nil)
        #expect(pc.learnedNameServer == nil)
        #expect(pc.dhcp?.state == .selecting)
    }

    @Test func manualRenewalsKeepASingleRetransmissionChain() throws {
        var config = pool
        config.leaseS = 800 // bound at 0.5 s: T1 400.5 s, T2 700.5 s, expiry 800.5 s
        let (sim, srv, pc) = try direct(config)
        try pc.setDhcp(true)
        sim.run(1 * S)
        try srv.configureDhcpServer(nil) // alive but deaf: every REQUEST leaves, none is answered
        sim.sched.runUntil(100 * S)
        pc.dhcp?.renewNow()
        sim.sched.runUntil(150 * S)
        pc.dhcp?.renewNow()
        sim.sched.runUntil(700 * S)
        // Each renewal supersedes the previous chain; from T1 the retries halve the time to T2, at least 60 s.
        #expect(Array(clientRequests(sim).dropFirst()) == [
            "100000 10.0.0.1", "150000 10.0.0.1", "400500 10.0.0.1", "550500 10.0.0.1", "625500 10.0.0.1", "685500 10.0.0.1",
        ])
    }

    @Test func aManualRenewalWhileRebindingRebroadcastsAndStaysRebinding() throws {
        var config = pool
        config.leaseS = 800
        let (sim, srv, pc) = try direct(config)
        try pc.setDhcp(true)
        sim.run(1 * S)
        try srv.configureDhcpServer(nil)
        sim.sched.runUntil(720 * S)
        #expect(pc.dhcp?.state == .rebinding)
        pc.dhcp?.renewNow()
        #expect(pc.dhcp?.state == .rebinding)
        sim.sched.runUntil(800 * S)
        // One chain before expiry: T2, the manual broadcast, then 60 s later (the 760.5 s retry of the T2 chain is gone).
        #expect(Array(clientRequests(sim).suffix(3)) == ["700500 255.255.255.255", "720000 255.255.255.255", "780000 255.255.255.255"])
    }

    @Test func aRenewalTheServerCannotHonourIsNakedAndTheClientStartsOver() throws {
        var config = pool
        config.leaseS = 60
        let (sim, srv, pc) = try direct(config)
        try pc.setDhcp(true)
        sim.run(1 * S)
        config.start = "10.0.0.150"
        try srv.configureDhcpServer(config)
        #expect(srv.dhcpServer?.view().count == 1) // a pool change keeps existing bindings
        sim.run(31 * S)
        #expect(Array(dhcpTx(sim).suffix(6)) == [
            "C Request 10.0.0.100→10.0.0.1",
            "S NAK 10.0.0.1→255.255.255.255",
            "C Discover 0.0.0.0→255.255.255.255",
            "S Offer 10.0.0.1→255.255.255.255",
            "C Request 0.0.0.0→255.255.255.255",
            "S ACK 10.0.0.1→255.255.255.255",
        ])
        #expect(try pc.iface("eth0").ipv4?.addr == ip("10.0.0.150"))
    }

    @Test func leavingDhcpModeReleasesTheLeaseAndRemovesTheAddress() throws {
        let (sim, srv, pc) = try direct()
        try pc.setDhcp(true)
        sim.run(1 * S)
        try pc.setDhcp(false)
        #expect(pc.dhcp == nil)
        #expect(try pc.iface("eth0").ipv4 == nil)
        #expect(pc.routes.lookup(ip("8.8.8.8")) == nil)
        sim.run(1 * MS)
        // The RELEASE waited for ARP, whose reply came after the address was gone: it still leaves.
        #expect(dhcpTx(sim).last == "C Release 10.0.0.100→10.0.0.1")
        #expect(srv.dhcpServer?.view() == [])
    }

    @Test func aPowerCycleForgetsTheAddressAndGetsTheSameLeaseBack() throws {
        let (sim, srv, pc) = try direct()
        try pc.setDhcp(true)
        sim.run(1 * S)
        pc.powered = false
        pc.reset()
        #expect(try pc.iface("eth0").ipv4 == nil)
        #expect(pc.dhcp?.state == .initial)
        sim.run(10 * S)
        #expect(dhcpTx(sim).count == 4) // silent while off
        pc.powered = true
        pc.powerOn()
        sim.run(1 * MS)
        #expect(try pc.iface("eth0").ipv4?.addr == ip("10.0.0.100"))
        #expect(srv.dhcpServer?.view().count == 1)
    }

    @Test func aRouterServesOnlyThePoolsOwnSegmentAndNeverForwardsTheBroadcast() throws {
        let sim = Sim()
        let r = Router(sim: sim, id: "R", ports: 2)
        let near = Host(sim: sim, id: "N")
        let far = Host(sim: sim, id: "F")
        _ = try Link(sim: sim, try near.iface("eth0"), try r.iface("Gi0/0"))
        _ = try Link(sim: sim, try far.iface("eth0"), try r.iface("Gi0/1"))
        try r.setIp("Gi0/0", "10.0.0.1/24")
        try r.setIp("Gi0/1", "10.0.1.1/24")
        try r.configureDhcpServer(DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", gateway: "10.0.0.1"))
        try near.setDhcp(true)
        try far.setDhcp(true)
        sim.run(1 * S)
        #expect(near.interfaces[0].ipv4?.addr == ip("10.0.0.100"))
        #expect(far.interfaces[0].ipv4 == nil)
        #expect(!sim.log.all.contains { $0.kind == .tx && $0.node == "R" && $0.iface == "Gi0/1" })
    }

    @Test func pingsAnAddressBeforeOfferingItAndSkipsOneInUse() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW")
        for i in 1...4 { try sw.setSwitchport("Gi0/\(i)", PortConfig(portfast: true)) } // hosts on edge ports: forwarding once cabled
        let srv = Host(sim: sim, id: "S")
        let fixed = Host(sim: sim, id: "P")
        let pc = Host(sim: sim, id: "C")
        for (i, h) in [srv, fixed, pc].enumerated() { _ = try Link(sim: sim, try h.iface("eth0"), try sw.iface("Gi0/\(i + 1)")) }
        try srv.setIp("eth0", "10.0.0.1/24")
        try fixed.setIp("eth0", "10.0.0.100/24") // static, inside the pool
        try srv.configureDhcpServer(pool)
        try pc.setDhcp(true)
        sim.run(2 * S)
        #expect(pc.interfaces[0].ipv4?.addr == ip("10.0.0.101"))
        #expect(srv.dhcpServer?.conflicts == [ip("10.0.0.100")])
        #expect(srv.dhcpServer?.view().map { formatIp($0.ip) } == ["10.0.0.101"])
        // IOS-style conflict detection: one echo per candidate, the OFFER only after 500 ms of silence.
        let offer = try #require(sim.log.all.first { e in
            guard e.kind == .tx, e.node == "S", case .ipv4(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .dhcp(let m) = u.payload else { return false }
            return m.type == .offer
        })
        #expect(offer.time > 2 * DHCP_PROBE_WAIT_NS)
    }

    @Test func rejectsPoolsOutsideTheSubnetAndMalformedSettings() throws {
        let (_, srv, _) = try direct()
        let bad: [(DhcpConfig, String)] = [
            (DhcpConfig(start: "10.0.1.100", end: "10.0.1.199"), "DHCP pool 10.0.1.100-10.0.1.199 is outside the subnets of S"),
            (DhcpConfig(start: "10.0.0.0", end: "10.0.0.10"), "is outside the subnets of S"),
            (DhcpConfig(start: "10.0.0.200", end: "10.0.0.100"), "DHCP pool start 10.0.0.200 is after its end 10.0.0.100"),
            (DhcpConfig(start: "10.0.0.100", end: "10.0.0.300"), "Invalid IPv4 address"),
            (DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", excluded: ["10.0.0.5-"]), "Invalid excluded range: \"10.0.0.5-\""),
            (DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", gateway: "10.0.9.1"), "Gateway 10.0.9.1 is outside the pool's subnet 10.0.0.0/24"),
            (DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", dns: "dns"), "Invalid IPv4 address"),
            (DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", leaseS: 5), "Lease time must be between 10 s and 365 days"),
        ]
        for (config, message) in bad { expectError(message) { try srv.configureDhcpServer(config) } }
        #expect(srv.dhcpServer?.pool.config == pool)
        // A saved pool whose subnet changed since still loads (and stays silent).
        try srv.configureDhcpServer(DhcpConfig(start: "10.0.1.100", end: "10.0.1.199"), requireInSubnet: false)
        #expect(srv.dhcpServer?.pool.config.start == "10.0.1.100")
        try srv.configureDhcpServer(nil)
        #expect(srv.dhcpServer == nil)
    }

    @Test func suggestsAPoolInsideTheSubnet() {
        #expect(suggestedDhcpConfig(cidr: "192.168.1.1/24") == DhcpConfig(start: "192.168.1.100", end: "192.168.1.199"))
        #expect(suggestedDhcpConfig(cidr: "10.0.0.1/28") == DhcpConfig(start: "10.0.0.8", end: "10.0.0.14"))
        #expect(suggestedDhcpConfig(cidr: "10.0.0.1/31") == nil)
        #expect(suggestedDhcpConfig(cidr: "nonsense") == nil)
    }
}
