import Testing
@testable import PacEngine

private func rule(_ iface: String, _ direction: FirewallDirection, _ action: FirewallAction, _ proto: FirewallProto = .any,
                  _ src: String = "any", _ dst: String = "any", port: Int? = nil) -> FirewallRule {
    FirewallRule(iface: iface, direction: direction, action: action, proto: proto, src: src, dst: dst, port: port)
}

/// routedPair(): H1 10.0.1.10 — R1 (Gi0/0 10.0.1.1 | Gi0/1 10.0.2.1) — H2 10.0.2.10.
@Suite struct FirewallTests {
    @Test func theFirstMatchingRuleDecidesAndDenialsAreLoggedWithTheirReason() throws {
        let (sim, h1, _, r1) = try routedPair()
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [
            rule("Gi0/0", .inbound, .deny, .icmp, "any", "10.0.2.10"),
            rule("Gi0/0", .inbound, .allow, .icmp),
        ]))
        let denied = try Ping(node: h1, target: "10.0.2.10")
        sim.run(15 * S)
        let toRouter = try Ping(node: h1, target: "10.0.2.1") // for R1 itself: rule 1 does not match, rule 2 does
        sim.run(5 * S)
        #expect(denied.result.lines.contains("4 packets transmitted, 0 received, 100% packet loss"))
        #expect(toRouter.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        let drop = try #require(sim.log.all.first { $0.reason == .firewallRule })
        #expect(drop.node == "R1" && drop.iface == "Gi0/0" && eventView(drop).info.hasPrefix("10.0.1.10 → 10.0.2.10 Echo request"))
        #expect(eventView(drop).reason == "firewall-rule")
        #expect(drops(sim, .firewallRule) == 4 && drops(sim, .firewallDefault) == 0)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [
            rule("Gi0/0", .inbound, .allow, .icmp),
            rule("Gi0/0", .inbound, .deny, .icmp, "any", "10.0.2.10"),
        ]))
        let swapped = try Ping(node: h1, target: "10.0.2.10")
        sim.run(5 * S)
        #expect(swapped.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
    }

    @Test func withADefaultDenyOnlyRepliesAndErrorsAboutAllowedFlowsGetBack() throws {
        let (sim, h1, h2, r1) = try routedPair()
        try h2.configureSink(true)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [rule("Gi0/0", .inbound, .allow)], defaultAction: .deny))
        let out = try Ping(node: h1, target: "10.0.2.10")
        sim.run(5 * S)
        let flow = try TcpFlow(node: h1, target: "10.0.2.10", bytes: 100_000)
        sim.run(1 * S)
        let trace = try Traceroute(node: h1, target: "10.0.2.10")
        sim.run(1 * S)
        let back = try Ping(node: h2, target: "10.0.1.10")
        let toRouter = try Ping(node: h2, target: "10.0.2.1")
        sim.run(15 * S)
        #expect(out.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(flow.result.lines.last == "iperf Done.")
        #expect(trace.result.done && trace.result.lines[2].hasPrefix(" 2  10.0.2.10 (10.0.2.10)")) // H2's port unreachable is RELATED
        #expect(back.result.lines.contains("4 packets transmitted, 0 received, 100% packet loss"))
        #expect(toRouter.result.lines.contains("4 packets transmitted, 0 received, 100% packet loss")) // the default covers R1 itself
        #expect(drops(sim, .firewallDefault) == 8 && drops(sim, .firewallRule) == 0)
        #expect(sim.log.all.filter { $0.reason == .firewallDefault }.allSatisfy { $0.node == "R1" && $0.iface == "Gi0/1" })
    }

    @Test func portRulesMatchTheDestinationPortAndOutboundRulesFilterOnTheWayOut() throws {
        let (sim, h1, h2, r1) = try routedPair()
        try h2.configureSink(true)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [
            rule("Gi0/0", .inbound, .deny, .tcp, "10.0.1.0/24", "10.0.2.10", port: 9),
            rule("Gi0/1", .outbound, .deny, .udp, port: 9),
        ]))
        let tcp = try TcpFlow(node: h1, target: "10.0.2.10", bytes: 1000)
        _ = try UdpFlow(node: h1, target: "10.0.2.10", bitsPerSecond: 1e6, seconds: 1)
        sim.run(2 * S)
        let atIn = sim.log.all.filter { $0.reason == .firewallRule && $0.iface == "Gi0/0" }
        #expect(atIn.count == 2 && atIn.allSatisfy { eventView($0).info.contains("[SYN]") }) // the SYN and its retransmission at 1 s
        #expect(sim.log.all.filter { $0.reason == .firewallRule && $0.iface == "Gi0/1" }.count == 86) // every datagram to port 9
        #expect(h2.tcp.connections.isEmpty && !tcp.result.done)
        h1.sendUdp(try parseIp("10.0.2.10"), srcPort: 5000, dstPort: 7, data: [0]) // another port: allowed by default
        sim.run(10 * MS)
        #expect(sim.log.all.contains { $0.kind == .tx && $0.node == "H2" && eventView($0).info.contains("Destination unreachable (port)") })
    }

    @Test func rejectsRulesThatCannotMatch() throws {
        let (_, _, _, r1) = try routedPair()
        let make = { (r: FirewallRule) in _ = try Firewall(node: r1, config: FirewallConfig(rules: [r])) }
        expectError("R1 has no interface Gi0/7") { try make(rule("Gi0/7", .inbound, .deny)) }
        expectError("Invalid IPv4 address: \"10.0.0\"") { try make(rule("Gi0/0", .inbound, .deny, .any, "10.0.0")) }
        expectError("Invalid CIDR: \"10.0.0.0/33\"") { try make(rule("Gi0/0", .inbound, .deny, .any, "any", "10.0.0.0/33")) }
        expectError("A port needs TCP or UDP") { try make(rule("Gi0/0", .inbound, .deny, .icmp, port: 80)) }
        expectError("Port must be between 1 and 65535") { try make(rule("Gi0/0", .inbound, .deny, .tcp, port: 0)) }
    }
}
