import PacEngine
import Testing
@testable import PacKit

@Suite struct HelpersTests {
    private func snapshot() throws -> Snapshot {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "c", kind: .pc, name: "PC3"))
        try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "r", iface: "Gi0/0"), b: IfaceRef(node: "a", iface: "eth0")))
        try rt.handle(.setIp(node: "r", iface: "Gi0/1", cidr: "10.0.0.1/24"))
        try rt.handle(.addRoute(node: "r", cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        return rt.snapshot()
    }

    @Test func picksTheLowestFreeDefaultNamePerKind() throws {
        let nodes = try snapshot().nodes
        #expect(defaultName(.pc, existing: nodes) == "PC2")
        #expect(defaultName(.router, existing: nodes) == "R2")
        #expect(defaultName(.switch, existing: nodes) == "SW1")
    }

    @Test func findsFreePortsFirstIpAndGateway() throws {
        let nodes = try snapshot().nodes
        let r = nodes[2]
        #expect(firstFreeIface(r) == "Gi0/1")
        #expect(firstIp(r) == "10.0.0.1")
        #expect(gatewayOf(r) == "10.0.0.254")
        #expect(firstFreeIface(nodes[0]) == nil)
    }

    @Test func comparesTopologiesIgnoringPositions() throws {
        let s = try snapshot()
        let a = makeTopology(s, [:])
        let moved = makeTopology(s, ["a": Pos(x: 9, y: 9)])
        var renamed = a
        renamed.nodes[0].name = "X"
        #expect(sameNetwork(a, moved))
        #expect(!sameNetwork(a, renamed))
        #expect(positions(of: moved)["a"] == Pos(x: 9, y: 9))
    }

    @Test func snapsToTheGrid() {
        #expect(snap(Pos(x: 20, y: 6)) == Pos(x: 14, y: 0))
        #expect(snap(Pos(x: 22, y: -8)) == Pos(x: 28, y: -14))
    }
}
