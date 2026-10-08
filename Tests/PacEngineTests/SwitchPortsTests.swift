import Testing
@testable import PacEngine

@Suite struct SwitchPortsTests {
    @Test func aSwitchGrowsTo24And48PortsAndShrinksOnlyOverFreePorts() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.setPorts(id: "s", count: 24))
        #expect(rt.snapshot().nodes[0].ifaces.map(\.name).last == "Gi0/24")
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/20")))
        expectError("Gi0/20 is connected") { try rt.handle(.setPorts(id: "s", count: 8)) }
        #expect(rt.snapshot().nodes[0].ifaces.count == 24)
        expectError("A switch has 8, 24 or 48 ports") { try rt.handle(.setPorts(id: "s", count: 12)) }
        expectError("PC1 cannot change its ports") { try rt.handle(.setPorts(id: "a", count: 24)) }
        try rt.handle(.setPorts(id: "s", count: 48))
        #expect(rt.snapshot().nodes[0].ifaces.count == 48)
    }

    @Test func shrinkingRightAfterUnpluggingWithAFrameOnTheWireKeepsRunning() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.setPorts(id: "s", count: 24))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/20")))
        try rt.handle(.updateLink(id: "l", options: LinkOptions(bandwidthBps: 1000))) // a 64 B ARP frame takes ~0.7 s to send
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        rt.advance(wallMs: 10)
        try rt.handle(.disconnect(id: "l"))
        try rt.handle(.setPorts(id: "s", count: 8)) // Gi0/20 goes while the link still has a frame to finish
        for _ in 0..<30 { rt.advance(wallMs: 100) }
        #expect(rt.snapshot().nodes[0].ifaces.count == 8)
    }

    @Test func aSavedSizeComesBackOnLoad() throws {
        let rt = Runtime()
        let sw = TopologyNode(id: "s", kind: .switch, name: "SW1", pos: Pos(x: 0, y: 0),
                              ifaces: (1...24).map { TopologyIface(name: "Gi0/\($0)", cidr: nil) }, routes: [])
        try rt.handle(.load(Topology(nodes: [sw])))
        #expect(rt.snapshot().nodes[0].ifaces.count == 24)
    }
}
