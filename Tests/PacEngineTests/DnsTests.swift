import Testing
@testable import PacEngine

private let records = [
    DnsRecord(name: "srv.lab", ip: "10.0.0.53", ttl: 60),
    DnsRecord(name: "WWW.lab.", ip: "10.0.0.80", ttl: 300),
    DnsRecord(name: "www.lab", ip: "10.0.0.81", ttl: 300),
]

/// Client C (10.0.0.10, name server 10.0.0.53) cabled straight to DNS server S (10.0.0.53).
private func dnsPair() throws -> (sim: Sim, srv: Host, pc: Host) {
    let sim = Sim()
    let srv = Host(sim: sim, id: "S")
    let pc = Host(sim: sim, id: "C")
    _ = try Link(sim: sim, try pc.iface("eth0"), try srv.iface("eth0"))
    try srv.setIp("eth0", "10.0.0.53/24")
    try pc.setIp("eth0", "10.0.0.10/24")
    try srv.configureDnsServer(records)
    pc.nameServer = try parseIp("10.0.0.53")
    return (sim, srv, pc)
}

/// DNS queries `node` put on the wire.
private func queries(_ sim: Sim, from node: String) -> Int {
    sim.log.all.filter { e in
        guard e.kind == .tx, e.node == node, case .ipv4(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .dns(let m) = u.payload else { return false }
        return !m.response
    }.count
}

@Suite struct DnsTests {
    @Test func nslookupPrintsEveryAddressLikeBindAndBypassesTheCache() throws {
        let (sim, srv, pc) = try dnsPair()
        let n = try NsLookup(node: pc, name: "WWW.Lab")
        sim.run(1 * S)
        #expect(n.result.done)
        #expect(n.result.lines == [
            "Server:\t\t10.0.0.53", "Address:\t10.0.0.53#53", "",
            "Name:\twww.lab", "Address: 10.0.0.80", "Name:\twww.lab", "Address: 10.0.0.81", "",
        ])
        #expect(pc.resolver.entries().isEmpty)
        #expect(srv.dnsServer?.records.map(\.name) == ["srv.lab", "www.lab", "www.lab"])
    }

    @Test func nslookupReportsNxdomainAndTimesOutAfterTwoAttempts() throws {
        let (sim, srv, pc) = try dnsPair()
        let missing = try NsLookup(node: pc, name: "nope.lab")
        sim.run(1 * S)
        #expect(Array(missing.result.lines.suffix(2)) == ["** server can't find nope.lab: NXDOMAIN", ""])
        srv.powered = false
        let silent = try NsLookup(node: pc, name: "srv.lab")
        sim.run(10 * S - 1)
        #expect(!silent.result.done)
        sim.run(1)
        #expect(Array(silent.result.lines.suffix(2)) == [";; connection timed out; no servers could be reached", ""])
        #expect(queries(sim, from: "C") == 3) // the NXDOMAIN query + 2 attempts 5 s apart
    }

    @Test func rejectsBadNamesAndHostsWithoutAServer() throws {
        let (_, _, pc) = try dnsPair()
        expectError("Invalid host name: \"bad_name\"") { _ = try NsLookup(node: pc, name: "bad_name") }
        expectError("Invalid host name") { _ = try NsLookup(node: pc, name: "-x.lab") }
        expectError("Invalid host name") { _ = try NsLookup(node: pc, name: "10.0.0.1") }
        pc.nameServer = nil
        expectError("C has no DNS server configured") { _ = try NsLookup(node: pc, name: "srv.lab") }
        #expect(normalizeHostName(" Srv.LAB. ") == "srv.lab")
        #expect(normalizeHostName("a..b") == nil)
        #expect(normalizeHostName(String(repeating: "a", count: 64)) == nil)
    }

    @Test func dnsServerRejectsMalformedAndDuplicateRecords() throws {
        let (_, srv, _) = try dnsPair()
        expectError("Invalid host name: \"a b\"") { try srv.configureDnsServer([DnsRecord(name: "a b", ip: "10.0.0.1")]) }
        expectError("Invalid IPv4 address") { try srv.configureDnsServer([DnsRecord(name: "a.lab", ip: "10.0.0")]) }
        expectError("TTL must be between 0 and 2147483647 s") { try srv.configureDnsServer([DnsRecord(name: "a.lab", ip: "10.0.0.1", ttl: -1)]) }
        expectError("Record www.lab A 10.0.0.80 already exists") { try srv.configureDnsServer(records + [DnsRecord(name: "www.lab", ip: "10.0.0.80")]) }
        #expect(srv.dnsServer?.records.count == 3)
        try srv.configureDnsServer(nil)
        #expect(srv.dnsServer == nil)
    }

    @Test func pingResolvesNamesThroughACacheThatHonoursTheTtl() throws {
        let (sim, _, pc) = try dnsPair()
        let first = try Ping(node: pc, target: "srv.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(first.result.lines.first == "PING srv.lab (10.0.0.53) 56(84) bytes of data.")
        #expect(first.result.lines.last == "1 packets transmitted, 1 received, 0% packet loss")
        #expect(pc.resolver.entries().map(\.name) == ["srv.lab"])
        let second = try Ping(node: pc, target: "srv.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(second.result.received == 1)
        #expect(queries(sim, from: "C") == 1) // answered from the cache
        sim.run(57 * S) // past the record's 60 s TTL
        #expect(pc.resolver.entries().isEmpty)
        let third = try Ping(node: pc, target: "srv.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(third.result.received == 1)
        #expect(queries(sim, from: "C") == 2)
    }

    @Test func pingAndTracerouteReportNamesThatDoNotResolve() throws {
        let (sim, _, pc) = try dnsPair()
        let ping = try Ping(node: pc, target: "nope.lab")
        let trace = try Traceroute(node: pc, target: "srv.lab")
        let lost = try Traceroute(node: pc, target: "nope.lab")
        sim.run(1 * S)
        #expect(ping.result.lines == ["ping: nope.lab: Name or service not known"])
        #expect(ping.result.done && ping.result.transmitted == 0)
        #expect(trace.result.lines.first == "traceroute to srv.lab (10.0.0.53), 30 hops max, 60 byte packets")
        #expect(lost.result.lines == ["nope.lab: Name or service not known", "Cannot handle \"host\" cmdline arg `nope.lab' on position 1 (argc 1)"])
        pc.nameServer = nil
        let offline = try Ping(node: pc, target: "other.lab")
        #expect(offline.result.lines == ["ping: other.lab: Temporary failure in name resolution"])
        expectError("Invalid IPv4") { _ = try Ping(node: pc, target: "10.0.0.300") }
        expectError("Invalid address or host name: \"bad_name\"") { _ = try Ping(node: pc, target: "bad_name") }
    }

    @Test func aPowerCycleEmptiesTheCache() throws {
        let (sim, _, pc) = try dnsPair()
        let ping = try Ping(node: pc, target: "srv.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping.result.received == 1)
        pc.reset()
        #expect(pc.resolver.entries().isEmpty)
    }
}
