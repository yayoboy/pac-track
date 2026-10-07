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
}

func expectError(_ fragment: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected an error containing \"\(fragment)\"", sourceLocation: sourceLocation)
    } catch {
        #expect("\(error)".contains(fragment), "got: \(error)", sourceLocation: sourceLocation)
    }
}
