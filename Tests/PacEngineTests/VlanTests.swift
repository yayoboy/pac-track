import Testing
@testable import PacEngine

/// Probes on the switch's first ports, in order.
private func probes(_ sim: Sim, _ sw: Switch, _ names: [String]) throws -> [Probe] {
    try names.enumerated().map { i, name in
        let p = Probe(sim: sim, id: name)
        _ = try Link(sim: sim, try p.iface("eth0"), sw.interfaces[i])
        return p
    }
}

private func cable(_ rt: Runtime, _ id: String, _ a: String, _ ai: String, _ b: String, _ bi: String) throws {
    try rt.handle(.connect(id: id, a: IfaceRef(node: a, iface: ai), b: IfaceRef(node: b, iface: bi)))
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct VlanTests {
    @Test func accessPortsFloodOnlyInsideTheirVlanUntaggedAndAVlanChangeFlushesThePort() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try probes(sim, sw, ["A", "B", "C"])
        try sw.setSwitchport("Gi0/1", PortConfig(vlan: 10))
        try sw.setSwitchport("Gi0/2", PortConfig(vlan: 10))
        try sw.setSwitchport("Gi0/3", PortConfig(vlan: 20))
        try p[0].sendRaw()
        sim.run(MS)
        #expect(p.map { $0.got.count } == [0, 1, 0])
        #expect(p[1].got[0].frame.vlan == nil)
        #expect(sw.macTable().map { "\($0.vlan) \($0.mac) \($0.iface)" } == ["10 \(try p[0].iface("eth0").mac) Gi0/1"])
        try p[2].sendRaw(try p[0].iface("eth0").mac) // VLAN 20 has not learned A: flooded in VLAN 20, which has no other port
        sim.run(MS)
        #expect(p[0].got.isEmpty)
        try sw.setSwitchport("Gi0/1", PortConfig(vlan: 20))
        #expect(sw.macTable().map { $0.iface } == ["Gi0/3"]) // A's entry went with the change; C's stays
    }

    @Test func aTrunkTagsEveryVlanButTheNativeAndAHubPassesTheTagOn() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try probes(sim, sw, ["A", "B"]) // A: access 10, B: access 1
        let hub = Hub(sim: sim, id: "HUB1")
        let t = Probe(sim: sim, id: "T")
        _ = try Link(sim: sim, try sw.iface("Gi0/8"), try hub.iface("p1"))
        _ = try Link(sim: sim, try hub.iface("p2"), try t.iface("eth0"))
        try sw.setSwitchport("Gi0/1", PortConfig(vlan: 10))
        try sw.setSwitchport("Gi0/8", PortConfig(mode: .trunk))
        try p[0].sendRaw()
        try p[1].sendRaw()
        sim.run(MS)
        #expect(t.got.map { "\($0.frame.vlan ?? 0) \($0.frame.size)" } == ["10 46", "0 42"]) // native VLAN 1 untagged
        try t.sendRaw(vlan: 10)
        try t.sendRaw()
        sim.run(MS)
        #expect(p[0].got.count == 1 && p[0].got[0].frame.vlan == nil)
        #expect(p[1].got.count == 1)
    }

    @Test func aTrunkCarriesOnlyItsAllowedVlansAndRefusesTheRestWithAReason() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try probes(sim, sw, ["A", "B", "T"])
        try sw.setSwitchport("Gi0/1", PortConfig(vlan: 20))
        try sw.setSwitchport("Gi0/2", PortConfig(vlan: 10))
        try sw.setSwitchport("Gi0/3", PortConfig(mode: .trunk, allowed: "1,10"))
        try p[0].sendRaw() // VLAN 20 does not leave on the trunk
        sim.run(MS)
        #expect(p[2].got.isEmpty)
        try p[2].sendRaw(vlan: 20) // not allowed on the trunk
        try p[1].sendRaw(vlan: 10) // tagged on an access port
        sim.run(MS)
        #expect(p[0].got.isEmpty && p[1].got.isEmpty)
        let refused = sim.log.all.filter { $0.reason == .vlanNotAllowed }.map { "\($0.node) \($0.iface ?? "")" }
        #expect(refused == ["SW1 Gi0/3", "SW1 Gi0/2"])
    }

    @Test func refusesInvalidVlanSettingsAndKeepsTheOldOnes() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        let set = { (c: PortConfig) in try rt.handle(.setSwitchport(node: "s", iface: "Gi0/1", config: c)) }
        expectError("VLAN must be between 1 and 4094") { try set(PortConfig(vlan: 0)) }
        expectError("VLAN must be between 1 and 4094") { try set(PortConfig(mode: .trunk, native: 4095)) }
        expectError("VLAN must be between 1 and 4094") { try set(PortConfig(mode: .trunk, allowed: "10-5000")) }
        expectError("Invalid VLAN list: \"10,abc\"") { try set(PortConfig(mode: .trunk, allowed: "10,abc")) }
        expectError("Invalid VLAN list: \"30-20\"") { try set(PortConfig(mode: .trunk, allowed: "30-20")) }
        expectError("Invalid VLAN list: \"\"") { try set(PortConfig(mode: .trunk, allowed: "")) }
        expectError("Native VLAN 1 is not allowed on the trunk") { try set(PortConfig(mode: .trunk, allowed: "10,20")) }
        expectError("PC1 has no switch ports") { try rt.handle(.setSwitchport(node: "a", iface: "eth0", config: PortConfig())) }
        #expect(rt.snapshot().nodes[0].ifaces[0].switchport == PortConfig())
        let trunk = PortConfig(mode: .trunk, allowed: "10, 20,30-35", native: 20)
        try set(trunk)
        #expect(rt.snapshot().nodes[0].ifaces[0].switchport == trunk)
        #expect(rt.snapshot().nodes[1].ifaces[0].switchport == nil)
    }

    /// Spec M7 §1, first half: two VLANs on two switches joined by a trunk; the same VLAN pings, the other one (same subnet) does not.
    @Test func twoVlansOnTwoSwitchesJoinedByATrunk() throws {
        let rt = Runtime()
        let devices: [(String, DeviceKind, String)] = [("a", .pc, "PC1"), ("b", .pc, "PC2"), ("c", .pc, "PC3"),
                                                       ("s1", .switch, "SW1"), ("s2", .switch, "SW2")]
        for (id, kind, name) in devices { try rt.handle(.addNode(id: id, kind: kind, name: name)) }
        try cable(rt, "1", "a", "eth0", "s1", "Gi0/1")
        try cable(rt, "2", "s1", "Gi0/8", "s2", "Gi0/8")
        try cable(rt, "3", "b", "eth0", "s2", "Gi0/1")
        try cable(rt, "4", "c", "eth0", "s2", "Gi0/2")
        let ports: [(String, String, PortConfig)] = [("s1", "Gi0/1", PortConfig(vlan: 10)), ("s1", "Gi0/8", PortConfig(mode: .trunk)),
                                                     ("s2", "Gi0/8", PortConfig(mode: .trunk)), ("s2", "Gi0/1", PortConfig(vlan: 10)),
                                                     ("s2", "Gi0/2", PortConfig(vlan: 20))]
        for (sw, port, config) in ports { try rt.handle(.setSwitchport(node: sw, iface: port, config: config)) }
        for (node, cidr) in [("a", "10.0.0.1/24"), ("b", "10.0.0.2/24"), ("c", "10.0.0.3/24")] {
            try rt.handle(.setIp(node: node, iface: "eth0", cidr: cidr))
        }
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        try rt.handle(.ping(node: "a", target: "10.0.0.3"))
        runFor(rt, wallMs: 6_000)
        let s = rt.snapshot()
        #expect(s.apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(s.apps[1].lines.contains { $0.hasSuffix("Destination Host Unreachable") })
        #expect(!s.apps[1].lines.contains { $0.contains("bytes from") })
        #expect(s.nodes[4].mac.filter { $0.iface == "Gi0/8" }.map(\.vlan) == [10]) // PC1, learned on SW2's trunk in VLAN 10
        #expect(rt.events(from: 0).contains { $0.kind == .tx && $0.node == "s1" && $0.iface == "Gi0/8" && $0.bytes == 102 })
    }
}
