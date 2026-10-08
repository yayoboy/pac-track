import Testing
@testable import PacEngine

private func cable(_ rt: Runtime, _ id: String, _ a: String, _ ai: String, _ b: String, _ bi: String) throws {
    try rt.handle(.connect(id: id, a: IfaceRef(node: a, iface: ai), b: IfaceRef(node: b, iface: bi)))
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

/// PC1 (VLAN 10, 10.0.10.10/24) and PC2 (VLAN 20, 10.0.20.10/24) on SW1's access ports Gi0/1 and Gi0/2; R1 Gi0/0 on SW1's trunk
/// Gi0/8 with Gi0/0.10 (10.0.10.1/24) and Gi0/0.20 (10.0.20.1/24), added 20 first; each PC's gateway is its subinterface.
private func stick() throws -> Runtime {
    let rt = Runtime()
    let devices: [(String, DeviceKind, String)] = [("a", .pc, "PC1"), ("b", .pc, "PC2"), ("s", .switch, "SW1"), ("r", .router, "R1")]
    for (id, kind, name) in devices { try rt.handle(.addNode(id: id, kind: kind, name: name)) }
    try cable(rt, "1", "a", "eth0", "s", "Gi0/1")
    try cable(rt, "2", "b", "eth0", "s", "Gi0/2")
    try cable(rt, "3", "r", "Gi0/0", "s", "Gi0/8")
    try rt.handle(.setSwitchport(node: "s", iface: "Gi0/1", config: PortConfig(vlan: 10)))
    try rt.handle(.setSwitchport(node: "s", iface: "Gi0/2", config: PortConfig(vlan: 20)))
    try rt.handle(.setSwitchport(node: "s", iface: "Gi0/8", config: PortConfig(mode: .trunk)))
    try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.20"))
    try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.10"))
    for (node, iface, cidr) in [("r", "Gi0/0.10", "10.0.10.1/24"), ("r", "Gi0/0.20", "10.0.20.1/24"),
                                ("a", "eth0", "10.0.10.10/24"), ("b", "eth0", "10.0.20.10/24")] {
        try rt.handle(.setIp(node: node, iface: iface, cidr: cidr))
    }
    try rt.handle(.addRoute(node: "a", cidr: "0.0.0.0/0", nextHop: "10.0.10.1"))
    try rt.handle(.addRoute(node: "b", cidr: "0.0.0.0/0", nextHop: "10.0.20.1"))
    return rt
}

@Suite struct SubinterfaceTests {
    @Test func pingsAcrossVlansThroughTheRouterWithTheTtlDecrementedOnce() throws {
        let rt = try stick()
        try rt.handle(.ping(node: "a", target: "10.0.20.10"))
        runFor(rt, wallMs: 6_000)
        let s = rt.snapshot()
        #expect(s.apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(s.apps[0].lines.contains { $0.hasPrefix("64 bytes from 10.0.20.10: icmp_seq=2 ttl=63") })
        let r = s.nodes[3]
        #expect(r.arp.map { "\($0.ip) \($0.iface)" } == ["10.0.10.10 Gi0/0.10", "10.0.20.10 Gi0/0.20"])
        #expect(r.routes.map { "\($0.dest) \($0.iface)" } == ["10.0.10.0/24 Gi0/0.10", "10.0.20.0/24 Gi0/0.20"])
        #expect(s.nodes[2].mac.filter { $0.iface == "Gi0/8" }.map(\.vlan) == [10, 20]) // R1's one MAC, in both VLANs
        let events = rt.events(from: 0)
        let fwd = try #require(events.first { $0.kind == .tx && $0.node == "r" && $0.info.hasPrefix("10.0.10.10 → 10.0.20.10 Echo request") })
        #expect(fwd.iface == "Gi0/0" && fwd.bytes == 102) // out of the physical interface, tagged
        let pdu = try #require(rt.pdu(fwd.id))
        #expect(pdu.map(\.title) == ["Ethernet II", "802.1Q", "IPv4", "ICMP"])
        #expect(pdu[1].fields.contains(PduField(name: "VLAN ID", value: "20")))
        #expect(events.contains { $0.kind == .rx && $0.node == "b" && $0.proto == .icmp && $0.bytes == 98 }) // untagged on the access port
    }

    @Test func subinterfacesShareThePhysicalMacAndFollowItInVlanOrder() throws {
        let r = try stick().snapshot().nodes[3]
        #expect(r.ifaces.map(\.name) == ["Gi0/0", "Gi0/0.10", "Gi0/0.20", "Gi0/1", "Gi0/2", "Gi0/3"])
        #expect(r.ifaces[1].mac == r.ifaces[0].mac && r.ifaces[2].mac == r.ifaces[0].mac)
        #expect(r.ifaces[1].linked && !r.ifaces[4].linked)
        #expect(r.ifaces[1].switchport == nil)
    }

    @Test func refusesBadSubinterfacesAndDeletingOneThatNatOrTheFirewallNames() throws {
        let rt = try stick()
        try rt.handle(.addNode(id: "isp", kind: .cloud, name: "ISP1"))
        expectError("VLAN must be between 1 and 4094") { try rt.handle(.addSubinterface(node: "r", iface: "Gi0/1.4095")) }
        expectError("Gi0/0.10 already exists") { try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.010")) }
        expectError("Invalid subinterface name: \"Gi0/0.x\"") { try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.x")) }
        expectError("Invalid subinterface name: \"Gi0/0\"") { try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0")) }
        expectError("has no interface Gi0/9") { try rt.handle(.addSubinterface(node: "r", iface: "Gi0/9.10")) }
        expectError("PC1 cannot have subinterfaces") { try rt.handle(.addSubinterface(node: "a", iface: "eth0.10")) }
        expectError("SW1 cannot have subinterfaces") { try rt.handle(.addSubinterface(node: "s", iface: "Gi0/1.10")) }
        expectError("ISP1 cannot have subinterfaces") { try rt.handle(.addSubinterface(node: "isp", iface: "Gi0/0.10")) }
        expectError("Gi0/1 is not a subinterface") { try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/1")) }
        expectError("Cannot cable a subinterface") { try cable(rt, "x", "r", "Gi0/0.10", "s", "Gi0/3") }
        try rt.handle(.setNat(node: "r", config: NatConfig(inside: ["Gi0/0.10"], outside: "Gi0/1")))
        expectError("Gi0/0.10 has a NAT role") { try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/0.10")) }
        try rt.handle(.setNat(node: "r", config: nil))
        let deny = FirewallRule(iface: "Gi0/0.20", direction: .inbound, action: .deny, proto: .icmp, src: "any", dst: "any")
        try rt.handle(.setFirewall(node: "r", config: FirewallConfig(rules: [deny])))
        expectError("Gi0/0.20 has firewall rules") { try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/0.20")) }
        try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/0.10"))
        #expect(rt.snapshot().nodes[3].ifaces.map(\.name) == ["Gi0/0", "Gi0/0.20", "Gi0/1", "Gi0/2", "Gi0/3"])
    }

    @Test func taggedFramesWithoutASubinterfaceAreDroppedAtRoutersAndHosts() throws {
        let rt = try stick()
        try rt.handle(.addNode(id: "c", kind: .pc, name: "PC3"))
        try cable(rt, "4", "c", "eth0", "s", "Gi0/7")
        try rt.handle(.setSwitchport(node: "s", iface: "Gi0/7", config: PortConfig(mode: .trunk))) // a PC on a trunk port
        try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/0.10"))
        try rt.handle(.ping(node: "a", target: "10.0.10.1")) // PC1's ARP broadcast reaches both trunks tagged 10
        runFor(rt, wallMs: 1_000)
        let refused = rt.events(from: 0).filter { $0.kind == .drop && $0.reason == "unknown-vlan" }
        #expect(Set(refused.map { "\($0.node) \($0.iface ?? "")" }) == ["r Gi0/0", "c eth0"])
    }

    @Test func aDeletedSubinterfaceDropsWhatStillArrivesForItsVlan() throws {
        let rt = try stick()
        try rt.handle(.ping(node: "a", target: "10.0.10.1"))
        runFor(rt, wallMs: 1_500) // two replies
        try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/0.10"))
        runFor(rt, wallMs: 3_000)
        #expect(rt.snapshot().apps[0].lines.filter { $0.contains("bytes from") }.count == 2)
        #expect(rt.events(from: 0).contains { $0.reason == "unknown-vlan" && $0.node == "r" && $0.proto == .icmp })
    }

    @Test func aDeletedSubinterfaceSendsNothingMore() throws {
        let rt = try stick()
        try rt.handle(.ping(node: "r", target: "10.0.10.99")) // nobody: ARP retries out of Gi0/0.10
        runFor(rt, wallMs: 500)
        try rt.handle(.removeSubinterface(node: "r", iface: "Gi0/0.10"))
        let removed = rt.events(from: 0).last?.id ?? 0
        runFor(rt, wallMs: 3_000)
        let after = rt.events(from: removed + 1)
        #expect(!after.contains { $0.kind == .tx && $0.node == "r" })
        #expect(after.contains { $0.kind == .drop && $0.node == "r" && $0.iface == "Gi0/0.10" && $0.reason == "iface-down" })
    }

    @Test func aSubinterfaceServesDhcpToItsVlan() throws {
        let rt = try stick()
        try rt.handle(.setDhcpServer(node: "r", config: DhcpConfig(start: "10.0.20.100", end: "10.0.20.199", gateway: "10.0.20.1")))
        try rt.handle(.setIfaceMode(node: "b", iface: "eth0", mode: .dhcp))
        runFor(rt, wallMs: 1_000)
        let b = rt.snapshot().nodes[1]
        #expect(b.ifaces[0].cidr == "10.0.20.100/24")
        #expect(b.routes.contains { $0.dhcp && $0.nextHop == "10.0.20.1" })
    }

    @Test func aFirewallRuleNamesASubinterface() throws {
        let rt = try stick()
        let deny = FirewallRule(iface: "Gi0/0.10", direction: .inbound, action: .deny, proto: .icmp, src: "any", dst: "any")
        try rt.handle(.setFirewall(node: "r", config: FirewallConfig(rules: [deny])))
        try rt.handle(.ping(node: "a", target: "10.0.20.10"))
        runFor(rt, wallMs: 2_000)
        #expect(!rt.snapshot().apps[0].lines.contains { $0.contains("bytes from") })
        #expect(rt.events(from: 0).contains { $0.reason == "firewall-rule" && $0.node == "r" && $0.iface == "Gi0/0.10" })
    }
}
