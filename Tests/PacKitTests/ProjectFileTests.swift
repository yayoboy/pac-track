import Foundation
import PacEngine
import Testing
@testable import PacKit

@Suite struct ProjectFileTests {
    @Test func roundTripsATopology() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "a", kind: .switch, name: "SW1", pos: Pos(x: 1, y: 2), ifaces: [TopologyIface(name: "Gi0/1", cidr: nil)], routes: []),
        ])
        #expect(try ProjectFile.decode(try ProjectFile.encode(t)) == t)
    }

    @Test func rejectsGarbageAndUnknownVersions() throws {
        expectError("Not a Pac-Track project file") { _ = try ProjectFile.decode(Data("{ not json".utf8)) }
        expectError("Not a Pac-Track project file") { _ = try ProjectFile.decode(Data(#"{"version":1,"seed":1,"nodes":[{"kind":"toaster"}],"links":[]}"#.utf8)) }
        expectError("Unsupported or corrupt") { _ = try ProjectFile.decode(Data(#"{"version":9,"seed":1,"nodes":[],"links":[]}"#.utf8)) }
    }

    @Test func roundTripsServicesAndInterfaceModes() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "s", kind: .server, name: "SRV1", pos: Pos(x: 1, y: 2), ifaces: [TopologyIface(name: "eth0", cidr: nil, mode: .dhcp)],
                         routes: [], nameServer: "10.0.0.2", dhcp: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", excluded: ["10.0.0.150"]),
                         dns: [DnsRecord(name: "a.lab", ip: "10.0.0.5", ttl: 60)]),
        ])
        #expect(try ProjectFile.decode(try ProjectFile.encode(t)) == t)
    }

    @Test func anM6FileOpensWithEverySwitchPortInVlan1() throws {
        let json = #"{"version":1,"seed":1,"links":[],"nodes":[{"id":"s","kind":"switch","name":"SW1","pos":{"x":0,"y":0},"routes":[],"ifaces":[{"name":"Gi0/1","mode":"static"},{"name":"Gi0/2"}]}]}"#
        let t = try ProjectFile.decode(Data(json.utf8))
        #expect(t.nodes[0].ifaces.allSatisfy { $0.switchport == nil })
        let rt = Runtime()
        try rt.handle(.load(t))
        #expect(rt.snapshot().nodes[0].ifaces.allSatisfy { $0.switchport == PortConfig() })
    }

    @Test func anM7aFileOpensWithPortFastOffAndDefaultPriorities() throws {
        let json = #"{"version":1,"seed":1,"links":[],"nodes":[{"id":"s","kind":"switch","name":"SW1","pos":{"x":0,"y":0},"routes":[],"ifaces":[{"name":"Gi0/1","switchport":{"mode":"access","vlan":10,"allowed":"all","native":1}}]}]}"#
        let t = try ProjectFile.decode(Data(json.utf8))
        #expect(t.nodes[0].ifaces[0].switchport == PortConfig(vlan: 10))
        #expect(t.nodes[0].stpPriorities == nil)
        let rt = Runtime()
        try rt.handle(.load(t))
        #expect(rt.snapshot().nodes[0].ifaces[0].switchport?.portfast == false && rt.snapshot().nodes[0].stpPriorities.isEmpty)
    }

    @Test func ripSurvivesSavingAndAnM7FileOpensWithRipOff() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
        try rt.handle(.setIp(node: "r", iface: "Gi0/1", cidr: "10.0.12.1/30"))
        try rt.handle(.setRip(node: "r", config: RipConfig(interfaces: ["Gi0/0", "Gi0/1"], passive: ["Gi0/0"])))
        let t = try ProjectFile.decode(try ProjectFile.encode(makeTopology(rt.snapshot(), [:])))
        #expect(t.nodes[0].rip == RipConfig(interfaces: ["Gi0/0", "Gi0/1"], passive: ["Gi0/0"]))
        let reopened = Runtime()
        try reopened.handle(.load(t))
        #expect(reopened.snapshot().nodes[0].rip == t.nodes[0].rip)
        let json = #"{"version":1,"seed":1,"links":[],"nodes":[{"id":"r","kind":"router","name":"R1","pos":{"x":0,"y":0},"routes":[],"ifaces":[{"name":"Gi0/0","cidr":"10.0.0.1/24"}]}]}"#
        let m7 = try ProjectFile.decode(Data(json.utf8))
        #expect(m7.nodes[0].rip == nil)
        let opened = Runtime()
        try opened.handle(.load(m7))
        #expect(opened.snapshot().nodes[0].rip == nil)
    }
}

func expectError(_ fragment: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected an error containing \"\(fragment)\"", sourceLocation: sourceLocation)
    } catch {
        #expect("\(error)".contains(fragment), "got: \(error)", sourceLocation: sourceLocation)
    }
}
