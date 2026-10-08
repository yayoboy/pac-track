import Testing
@testable import PacEngine

/// Two hosts on a 10 Mb/s, 1 ms cable.
private func slowPair() throws -> (sim: Sim, a: Host, b: Host) {
    let sim = Sim()
    let a = Host(sim: sim, id: "A")
    let b = Host(sim: sim, id: "B")
    _ = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"), LinkOptions(bandwidthBps: 10e6, propDelayNs: 1 * MS))
    try a.setIp("eth0", "10.0.0.1/24")
    try b.setIp("eth0", "10.0.0.2/24")
    return (sim, a, b)
}

@Suite struct PingTests {
    @Test func measuresRttExactlyArpPlusEchoFirstThenEchoOnly() throws {
        let (sim, a, _) = try slowPair()
        let p = try Ping(node: a, target: "10.0.0.2", options: PingOptions(count: 2))
        sim.run(12 * S)
        #expect(p.result.done)
        #expect(p.result.received == 2)
        // ARP 84 B wire @10 Mb/s = 67.2 µs, echo 122 B = 97.6 µs, +1 ms each way
        #expect(p.result.replies.map { $0.rttNs } == [4_329_600, 2_195_200])
        #expect(p.result.lines == [
            "PING 10.0.0.2 (10.0.0.2) 56(84) bytes of data.",
            "64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=4.330 ms",
            "64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=2.195 ms",
            "--- 10.0.0.2 ping statistics ---",
            "2 packets transmitted, 2 received, 0% packet loss",
        ])
    }

    @Test func pingsItsOwnAddressThroughLoopback() throws {
        let (sim, a, _) = try slowPair()
        let p = try Ping(node: a, target: "10.0.0.1", options: PingOptions(count: 1))
        sim.run(1 * MS)
        #expect(p.result.replies == [PingReply(seq: 1, from: "10.0.0.1", ttl: 64, rttNs: 0)])
        #expect(p.result.done)
        #expect(sim.log.all.filter { $0.kind == .tx }.isEmpty)
    }

    @Test func getsAReplyFromARoutersFarSideInterface() throws {
        let (sim, h1, _, _) = try routedPair()
        let p = try Ping(node: h1, target: "10.0.2.1", options: PingOptions(count: 1))
        sim.run(1 * S)
        #expect(p.result.replies.map { "\($0.from) \($0.ttl)" } == ["10.0.2.1 255"])
    }

    @Test func reportsTtlExceeded() throws {
        let (sim, h1, _, _) = try routedPair()
        let p = try Ping(node: h1, target: "10.0.2.10", options: PingOptions(count: 1, ttl: 1))
        sim.run(1 * S)
        #expect(p.result.errors == [PingError(seq: 1, from: "10.0.1.1", type: 11, code: 0)])
        #expect(p.result.lines.contains("From 10.0.1.1 icmp_seq=1 Time to live exceeded"))
    }

    @Test func reportsDestinationHostUnreachableFromAHostWithNoCable() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        let p = try Ping(node: h, target: "10.0.0.2", options: PingOptions(count: 1))
        sim.run(11 * S)
        #expect(p.result.received == 0)
        #expect(p.result.lines.contains("From 10.0.0.1 icmp_seq=1 Destination Host Unreachable"))
        #expect(p.result.lines.last == "1 packets transmitted, 0 received, +1 errors, 100% packet loss")
        #expect(drops(sim, .noLink) == 3)
    }

    @Test func failsFastWithNoRoute() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        let p = try Ping(node: h, target: "8.8.8.8")
        sim.run(1)
        #expect(p.result.done)
        #expect(p.result.transmitted == 0)
        #expect(p.result.lines[1] == "ping: connect: Network is unreachable")
    }

    @Test func stopEndsEarlyWithStatistics() throws {
        let (sim, a, _) = try slowPair()
        let p = try Ping(node: a, target: "10.0.0.2", options: PingOptions(count: 100))
        sim.run(1500 * MS)
        p.stop()
        #expect(p.result.done)
        #expect(p.result.transmitted == 2)
        #expect(p.result.lines.last == "2 packets transmitted, 2 received, 0% packet loss")
    }

    @Test func formatsMillisecondsLikeTypeScriptToFixed() {
        #expect(formatMs(62_500) == "0.063")
        #expect(formatMs(312_500) == "0.313")
        #expect(formatMs(4_329_600) == "4.330")
        #expect(formatMs(0) == "0.000")
    }

    @Test func releasesEverythingWhenTheSimulationIsDroppedMidPing() throws {
        weak var weakHost: Host?
        weak var weakPing: Ping?
        do {
            let (sim, a, _) = try slowPair()
            let p = try Ping(node: a, target: "10.0.0.2")
            weakHost = a
            weakPing = p
            sim.run(1500 * MS)
            #expect(!p.result.done)
        }
        #expect(weakPing == nil)
        #expect(weakHost == nil)
    }

    @Test func rejectsAnInvalidTarget() throws {
        let (_, a, _) = try slowPair()
        expectError("Invalid IPv4") { _ = try Ping(node: a, target: "10.0.0.300") }
    }

    @Test func rejectsInvalidOptionsSynchronously() throws {
        let (_, a, _) = try slowPair()
        let invalid = [PingOptions(size: -1), PingOptions(size: 65508), PingOptions(ttl: 0), PingOptions(ttl: 256),
                       PingOptions(count: 0), PingOptions(intervalNs: 0), PingOptions(timeoutNs: 0),
                       PingOptions(count: 10_001), PingOptions(intervalNs: 3601 * S), PingOptions(timeoutNs: 3601 * S)]
        for opts in invalid {
            expectError("Invalid ping option") { _ = try Ping(node: a, target: "10.0.0.2", options: opts) }
        }
    }
}
