import Testing
@testable import PacEngine

@Suite struct IpTests {
    // MARK: ARP + ICMP on a LAN

    @Test func resolvesMacsBothWaysAndAnswersEchoRequests() throws {
        let (sim, _, a, b) = try lan()
        let r = icmpSeen(a)
        #expect(a.sendPacket(try parseIp("10.0.0.2"), echoRequest()))
        sim.run(MS)
        #expect(a.arp.lookup(try parseIp("10.0.0.2")) == (try b.iface("eth0").mac))
        #expect(b.arp.lookup(try parseIp("10.0.0.1")) == (try a.iface("eth0").mac))
        #expect(r.seen == [Seen(from: "10.0.0.2", type: 0, code: 0, ttl: 64)])
    }

    @Test func reportsHostUnreachableToItselfAfterThreeUnansweredArpRequests() throws {
        let (sim, _, a, _) = try lan()
        let r = icmpSeen(a)
        a.sendPacket(try parseIp("10.0.0.99"), echoRequest())
        sim.run(2 * S)
        #expect(r.seen.isEmpty)
        sim.run(2 * S)
        #expect(r.seen == [Seen(from: "10.0.0.1", type: 3, code: 1, ttl: 64)])
        let arpTx = sim.log.all.filter {
            guard $0.kind == .tx, $0.node == "A", let f = $0.frame, case .arp = f.payload else { return false }
            return true
        }
        #expect(arpTx.count == 3)
        #expect(drops(sim, .arpTimeout) == 1)
    }

    @Test func answersClosedUdpPortsWithPortUnreachable() throws {
        let (sim, _, a, _) = try lan()
        let r = icmpSeen(a)
        a.sendUdp(try parseIp("10.0.0.2"), srcPort: 40000, dstPort: 9, data: [0, 0, 0, 0])
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.0.2", type: 3, code: 3, ttl: 64)])
    }

    @Test func deliversUdpToBoundPorts() throws {
        let (sim, _, a, b) = try lan()
        var got: [Int] = []
        try b.bindUdp(5000) { _, u, _ in got.append(u.payload.size) }
        expectError("in use") { try b.bindUdp(5000) { _, _, _ in } }
        a.sendUdp(try parseIp("10.0.0.2"), srcPort: 40000, dstPort: 5000, data: [UInt8](repeating: 0, count: 10))
        sim.run(MS)
        #expect(got == [10])
    }

    @Test func reportsFragmentationNeededForDfPacketsAboveTheMtu() throws {
        let (sim, _, a, _) = try lan()
        let r = icmpSeen(a)
        a.sendPacket(try parseIp("10.0.0.2"), echoRequest(1500))
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.0.1", type: 3, code: 4, ttl: 64)])
    }

    // MARK: routing through a router

    @Test func forwardsAndDecrementsTtl() throws {
        let (sim, h1, _, _) = try routedPair()
        let r = icmpSeen(h1)
        h1.sendPacket(try parseIp("10.0.2.10"), echoRequest())
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.2.10", type: 0, code: 0, ttl: 63)])
    }

    @Test func sendsTimeExceededWhenTtlRunsOut() throws {
        let (sim, h1, _, _) = try routedPair()
        let r = icmpSeen(h1)
        h1.sendPacket(try parseIp("10.0.2.10"), echoRequest(), ttl: 1)
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.1.1", type: 11, code: 0, ttl: 255)])
    }

    @Test func sendsNetUnreachableWhenTheRouterHasNoRoute() throws {
        let (sim, h1, _, _) = try routedPair()
        let r = icmpSeen(h1)
        h1.sendPacket(try parseIp("192.168.9.9"), echoRequest())
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.1.1", type: 3, code: 0, ttl: 255)])
    }

    @Test func refusesToOriginateWithoutARoute() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        #expect(!h.sendPacket(try parseIp("8.8.8.8"), echoRequest()))
    }

    // MARK: configuration validation

    @Test func rejectsBadAddressesAndKeepsTheOldOne() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        for bad in ["10.0.0.256/24", "10.0.0.1/33", "10.0.0.1", "abc"] {
            expectError("Invalid") { try h.setIp("eth0", bad) }
        }
        expectError("network or broadcast") { try h.setIp("eth0", "10.0.0.0/24") }
        expectError("network or broadcast") { try h.setIp("eth0", "10.0.0.255/24") }
        #expect(try h.iface("eth0").ipv4 == Cidr(addr: try parseIp("10.0.0.1"), prefix: 24))
    }

    @Test func rejectsOverlappingSubnetsOnOneNode() throws {
        let (_, _, _, r1) = try routedPair()
        expectError("overlaps") { try r1.setIp("Gi0/1", "10.0.1.2/24") }
        #expect(try r1.iface("Gi0/1").ipv4?.addr == (try parseIp("10.0.2.1")))
    }

    @Test func rejectsAGatewayOutsideConnectedSubnets() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        expectError("not in a connected subnet") { try h.setGateway("10.0.1.1") }
        #expect(h.routes.lookup(try parseIp("8.8.8.8")) == nil)
    }

    @Test func listsLiveArpEntriesUntilTheyExpire() throws {
        let (sim, _, a, b) = try lan()
        a.sendPacket(try parseIp("10.0.0.2"), echoRequest())
        sim.run(MS)
        let entries = a.arp.entries()
        #expect(entries.map { "\(formatIp($0.ip)) \($0.mac) \($0.iface)" } == ["10.0.0.2 \(try b.iface("eth0").mac) eth0"])
        sim.run(301 * S)
        #expect(a.arp.entries().isEmpty)
    }

    @Test func powerResetForgetsTheArpCache() throws {
        let (sim, _, a, _) = try lan()
        a.sendUdp(try parseIp("10.0.0.2"), srcPort: 1, dstPort: 9, data: [])
        sim.run(10 * MS)
        #expect(a.arp.entries().count == 1)
        a.reset()
        #expect(a.arp.entries().isEmpty)
    }

    @Test func broadcastsFromAnAddresslessInterfaceAndTellsUdpHandlersTheIngressInterface() throws {
        let (sim, _, a, b) = try lan()
        var got: [String] = []
        try b.bindUdp(67) { p, _, iface in got.append("\(formatIp(p.src)) → \(formatIp(p.dst)) on \(iface?.name ?? "-")") }
        try a.iface("eth0").ipv4 = nil
        a.broadcast(on: try a.iface("eth0"), src: 0, .udp(makeUdp(srcPort: 68, dstPort: 67, data: [])))
        sim.run(1 * MS)
        #expect(got == ["0.0.0.0 → 255.255.255.255 on eth0"])
        // a limited broadcast to a closed port draws no ICMP error
        #expect(!sim.log.all.contains { $0.kind == .tx && $0.node == "B" })
    }
}
