import Foundation
import Testing
@testable import PacEngine

private let NAT = NatConfig(inside: ["Gi0/0"], outside: "Gi0/1")
private let FIREWALL = FirewallConfig(rules: [FirewallRule(iface: "Gi0/0", direction: .inbound, action: .allow, proto: .any, src: "any", dst: "any")],
                                      defaultAction: .deny)

/// PC1 (192.168.1.10/24, gateway .1) — R1 (Gi0/0 192.168.1.1/24 inside, Gi0/1 203.0.113.1/24 outside; firewall: deny by default,
/// anything entering Gi0/0 allowed) — SRV1 (203.0.113.10/24, sink on, no gateway).
private func natRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
    try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "r", iface: "Gi0/1"), b: IfaceRef(node: "srv", iface: "eth0")))
    for (node, iface, cidr) in [("a", "eth0", "192.168.1.10/24"), ("r", "Gi0/0", "192.168.1.1/24"), ("r", "Gi0/1", "203.0.113.1/24"),
                                ("srv", "eth0", "203.0.113.10/24")] {
        try rt.handle(.setIp(node: node, iface: iface, cidr: cidr))
    }
    try rt.handle(.addRoute(node: "a", cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
    try rt.handle(.setNat(node: "r", config: NAT))
    try rt.handle(.setFirewall(node: "r", config: FIREWALL))
    try rt.handle(.setSink(node: "srv", on: true))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct RuntimeNatFirewallTests {
    @Test func showsTranslationsAndDropsAndForgetsTranslationsOnAPowerCycle() throws {
        let rt = try natRuntime()
        try rt.handle(.trafficTcp(node: "a", target: "203.0.113.10", bytes: 100_000))
        try rt.handle(.ping(node: "srv", target: "203.0.113.1"))
        runFor(rt, wallMs: 1_000)
        let s = rt.snapshot()
        let r = s.nodes[1]
        #expect(s.apps[0].lines.last == "iperf Done.") // NAT and a default-deny firewall on the same router
        #expect(r.nat == NAT && r.firewall == FIREWALL)
        #expect(s.nodes[0].nat == nil && s.nodes[0].firewall == nil && s.nodes[0].natTable.isEmpty)
        let row = try #require(r.natTable.first)
        let port = row.insideLocal.split(separator: ":")[1]
        #expect(r.natTable.count == 1 && row.proto == "tcp" && row.insideLocal == "192.168.1.10:\(port)")
        #expect(row.insideGlobal == "203.0.113.1:\(port)" && row.outside == "203.0.113.10:9")
        #expect((59...60).contains(row.ttlS)) // closed: a minute after its FIN
        #expect(rt.events(from: 0).contains { $0.kind == .drop && $0.node == "r" && $0.iface == "Gi0/1" && $0.reason == "firewall-default" })
        #expect(!s.apps[1].lines.contains { $0.contains("bytes from") }) // SRV1 may not ping R1
        try rt.handle(.setPower(id: "r", on: false))
        #expect(rt.snapshot().nodes[1].natTable.isEmpty && rt.snapshot().nodes[1].nat == NAT)
    }

    @Test func onlyRoutersRunNatAndAFirewallAndARefusedChangeKeepsTheOldOne() throws {
        let rt = try natRuntime()
        expectError("PC1 cannot run NAT") { try rt.handle(.setNat(node: "a", config: NAT)) }
        expectError("SRV1 cannot run a firewall") { try rt.handle(.setFirewall(node: "srv", config: FirewallConfig())) }
        expectError("Gi0/1 cannot be both inside and outside") {
            try rt.handle(.setNat(node: "r", config: NatConfig(inside: ["Gi0/1"], outside: "Gi0/1")))
        }
        expectError("A port needs TCP or UDP") {
            try rt.handle(.setFirewall(node: "r", config: FirewallConfig(rules: [
                FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .icmp, src: "any", dst: "any", port: 7),
            ])))
        }
        #expect(rt.snapshot().nodes[1].nat == NAT && rt.snapshot().nodes[1].firewall == FIREWALL)
        try rt.handle(.setNat(node: "r", config: nil))
        try rt.handle(.setFirewall(node: "r", config: nil))
        #expect(rt.snapshot().nodes[1].nat == nil && rt.snapshot().nodes[1].firewall == nil)
    }

    @Test func loadsNatAndFirewallAndOpensOlderFilesWithoutThem() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "r", kind: .router, name: "R1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "Gi0/0", cidr: "192.168.1.1/24")],
                         routes: [], nat: NAT, firewall: FIREWALL),
        ])
        let rt = Runtime()
        try rt.handle(.load(t))
        #expect(rt.snapshot().nodes[0].nat == NAT && rt.snapshot().nodes[0].firewall == FIREWALL)
        let old = #"{"id":"r","kind":"router","name":"R1","pos":{"x":0,"y":0},"ifaces":[],"routes":[]}"#
        let node = try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8))
        #expect(node.nat == nil && node.firewall == nil)
    }
}
