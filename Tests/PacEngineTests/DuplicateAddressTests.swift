import Testing
@testable import PacEngine

private func cable(_ rt: Runtime, _ id: String, _ a: String, _ ai: String, _ b: String, _ bi: String) throws {
    try rt.handle(.connect(id: id, a: IfaceRef(node: a, iface: ai), b: IfaceRef(node: b, iface: bi)))
}

/// PC1, PC2 and R1 Gi0/0 on SW1; PC3 on HUB1, which hangs off SW1; PC4 behind R1 Gi0/1.
private func lab() throws -> Runtime {
    let rt = Runtime()
    let devices: [(String, DeviceKind, String)] = [("a", .pc, "PC1"), ("b", .pc, "PC2"), ("c", .pc, "PC3"), ("d", .pc, "PC4"),
                                                   ("s", .switch, "SW1"), ("h", .hub, "HUB1"), ("r", .router, "R1")]
    for (id, kind, name) in devices { try rt.handle(.addNode(id: id, kind: kind, name: name)) }
    try cable(rt, "1", "a", "eth0", "s", "Gi0/1")
    try cable(rt, "2", "b", "eth0", "s", "Gi0/2")
    try cable(rt, "3", "h", "p1", "s", "Gi0/3")
    try cable(rt, "4", "c", "eth0", "h", "p2")
    try cable(rt, "5", "r", "Gi0/0", "s", "Gi0/4")
    try cable(rt, "6", "d", "eth0", "r", "Gi0/1")
    return rt
}

@Suite struct DuplicateAddressTests {
    @Test func anAddressInUseOnTheSameSegmentIsRefusedAcrossSwitchesAndHubs() throws {
        let rt = try lab()
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        expectError("Duplicate address: 10.0.0.1 is already used by PC1 eth0 on this segment") {
            try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.1/24"))
        }
        expectError("already used by PC1 eth0") { try rt.handle(.setIp(node: "c", iface: "eth0", cidr: "10.0.0.1/25")) } // through the hub
        expectError("already used by PC1 eth0") { try rt.handle(.setIp(node: "r", iface: "Gi0/0", cidr: "10.0.0.1/24")) }
        #expect(rt.snapshot().nodes[1].ifaces[0].cidr == nil) // nothing changed
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/16")) // its own address again
        try rt.handle(.setIp(node: "d", iface: "eth0", cidr: "10.0.0.1/24")) // behind R1: another segment
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.2/24"))
    }

    @Test func aDuplicateMadeByCablingStillOpensFromAFile() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "b", kind: .pc, name: "PC2"))
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.1/24")) // not cabled yet: another segment
        try cable(rt, "l1", "a", "eth0", "s", "Gi0/1")
        try cable(rt, "l2", "b", "eth0", "s", "Gi0/2") // a cable is never refused
        let origin = Pos(x: 0, y: 0)
        let pc = { (id: String, name: String) in
            TopologyNode(id: id, kind: .pc, name: name, pos: origin, ifaces: [TopologyIface(name: "eth0", cidr: "10.0.0.1/24")], routes: [])
        }
        let sw = TopologyNode(id: "s", kind: .switch, name: "SW1", pos: origin,
                              ifaces: (1...8).map { TopologyIface(name: "Gi0/\($0)", cidr: nil) }, routes: [])
        let links = [LinkView(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/1")),
                     LinkView(id: "l2", a: IfaceRef(node: "b", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2"))]
        try rt.handle(.load(Topology(nodes: [pc("a", "PC1"), pc("b", "PC2"), sw], links: links)))
        #expect(rt.snapshot().nodes.compactMap { $0.ifaces.first?.cidr } == ["10.0.0.1/24", "10.0.0.1/24"])
        #expect(rt.snapshot().links.count == 2)
    }

    @Test func aLeasedAddressIsNotConfigurationAndDoesNotBlockATypedOne() throws {
        let rt = try lab()
        try rt.handle(.setIp(node: "r", iface: "Gi0/0", cidr: "10.0.0.1/24"))
        try rt.handle(.setDhcpServer(node: "r", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199")))
        for _ in 0..<300 { rt.advance(wallMs: 100) } // ports reach forwarding after 2 × forward delay
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        for _ in 0..<10 { rt.advance(wallMs: 100) }
        #expect(rt.snapshot().nodes[0].ifaces[0].cidr == "10.0.0.100/24")
        // The lease is run-time state (the server's ping check guards its pool); only typed addresses conflict.
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.100/24"))
        expectError("already used by R1 Gi0/0") { try rt.handle(.setIp(node: "c", iface: "eth0", cidr: "10.0.0.1/24")) }
    }

    /// The segment is the broadcast domain: one VLAN, across access ports, the trunk's allowed list and subinterfaces.
    @Test func aDuplicateIsRefusedOnlyWithinTheSameVlan() throws {
        let rt = Runtime()
        let devices: [(String, DeviceKind, String)] = [("a", .pc, "PC1"), ("b", .pc, "PC2"), ("c", .pc, "PC3"), ("s", .switch, "SW1"),
                                                       ("r", .router, "R1")]
        for (id, kind, name) in devices { try rt.handle(.addNode(id: id, kind: kind, name: name)) }
        try cable(rt, "1", "a", "eth0", "s", "Gi0/1")
        try cable(rt, "2", "b", "eth0", "s", "Gi0/2")
        try cable(rt, "3", "c", "eth0", "s", "Gi0/3")
        try cable(rt, "4", "r", "Gi0/0", "s", "Gi0/8")
        let ports: [(String, PortConfig)] = [("Gi0/1", PortConfig(vlan: 10)), ("Gi0/2", PortConfig(vlan: 20)), ("Gi0/3", PortConfig(vlan: 10)),
                                             ("Gi0/8", PortConfig(mode: .trunk, allowed: "1,10"))]
        for (port, config) in ports { try rt.handle(.setSwitchport(node: "s", iface: port, config: config)) }
        try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.10"))
        try rt.handle(.addSubinterface(node: "r", iface: "Gi0/0.20"))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.1/24")) // VLAN 20: another broadcast domain
        expectError("already used by PC1 eth0") { try rt.handle(.setIp(node: "c", iface: "eth0", cidr: "10.0.0.1/24")) }
        expectError("already used by PC1 eth0") { try rt.handle(.setIp(node: "r", iface: "Gi0/0.10", cidr: "10.0.0.1/24")) } // over the trunk
        try rt.handle(.setIp(node: "r", iface: "Gi0/0.20", cidr: "10.0.0.1/24")) // the trunk does not carry VLAN 20
    }
}
