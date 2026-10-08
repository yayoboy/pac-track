import Foundation
import Testing
@testable import PacEngine

/// SW1 with SRV1 (10.0.0.2/24: DHCP .100–.199 handing out DNS 10.0.0.2, DNS record srv1.lab) and PC1, PC2 — all static at first.
private func servicesRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
    try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "b", kind: .pc, name: "PC2"))
    for (i, n) in ["srv", "a", "b"].enumerated() {
        try rt.handle(.connect(id: "l\(i)", a: IfaceRef(node: n, iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/\(i + 1)")))
    }
    try rt.handle(.setIp(node: "srv", iface: "eth0", cidr: "10.0.0.2/24"))
    try rt.handle(.setDnsServer(node: "srv", records: [DnsRecord(name: "srv1.lab", ip: "10.0.0.2")]))
    try rt.handle(.setDhcpServer(node: "srv", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", dns: "10.0.0.2")))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct RuntimeServicesTests {
    @Test func hostsInDhcpModeGetAddressesAndResolveNamesThroughTheServer() throws {
        let rt = try servicesRuntime()
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        try rt.handle(.setIfaceMode(node: "b", iface: "eth0", mode: .dhcp))
        runFor(rt, wallMs: 1_000)
        try rt.handle(.nslookup(node: "a", name: "srv1.lab"))
        try rt.handle(.ping(node: "b", target: "srv1.lab"))
        runFor(rt, wallMs: 6_000)
        let s = rt.snapshot()
        let (srv, a, b) = (s.nodes[1], s.nodes[2], s.nodes[3])
        #expect(a.ifaces[0].mode == .dhcp && a.ifaces[0].cidr == "10.0.0.100/24")
        #expect(b.ifaces[0].cidr == "10.0.0.101/24")
        #expect(a.dhcpClient == DhcpClientView(state: "BOUND", server: "10.0.0.2", leaseS: 86_394, renewS: 43_194)) // bound within the first µs, 7 s ago
        #expect(a.learnedNameServer == "10.0.0.2" && a.nameServer == nil)
        #expect(!a.routes.contains { $0.dhcp }) // the pool hands out no gateway
        #expect(srv.leases.map { "\($0.ip) \($0.bound)" } == ["10.0.0.100 true", "10.0.0.101 true"])
        #expect(srv.dhcpServer == DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", dns: "10.0.0.2"))
        #expect(srv.dnsRecords == [DnsRecord(name: "srv1.lab", ip: "10.0.0.2")])
        #expect(s.apps[0].title == "nslookup srv1.lab" && s.apps[0].lines.contains("Address: 10.0.0.2") && s.apps[0].done)
        #expect(s.apps[1].lines.first == "PING srv1.lab (10.0.0.2) 56(84) bytes of data.")
        #expect(b.dnsCache == [DnsCacheRow(name: "srv1.lab", ip: "10.0.0.2", ttlS: 3595)]) // cached at 1 s for 3600 s
        #expect(s.nodes[0].dhcpClient == nil && srv.dhcpClient == nil)
    }

    @Test func rejectsServicesOnTheWrongDevicesAndAddressesOnDhcpInterfaces() throws {
        let rt = try servicesRuntime()
        expectError("PC1 cannot run a DHCP server") {
            try rt.handle(.setDhcpServer(node: "a", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199")))
        }
        try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
        expectError("R1 cannot run a DNS server") { try rt.handle(.setDnsServer(node: "r", records: [])) }
        expectError("R1 has no DHCP client") { try rt.handle(.setIfaceMode(node: "r", iface: "Gi0/0", mode: .dhcp)) }
        expectError("SW1 has no IP stack") { try rt.handle(.setNameServer(node: "s", ip: "10.0.0.2")) }
        expectError("Invalid IPv4") { try rt.handle(.setNameServer(node: "a", ip: "10.0.0")) }
        expectError("PC1 is not using DHCP") { try rt.handle(.renewDhcp(node: "a")) }
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        expectError("eth0 is configured by DHCP") { try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.9/24")) }
        expectError("DHCP pool 10.0.1.1-10.0.1.9 is outside the subnets of SRV1") {
            try rt.handle(.setDhcpServer(node: "srv", config: DhcpConfig(start: "10.0.1.1", end: "10.0.1.9")))
        }
        expectError("Invalid host name") { try rt.handle(.nslookup(node: "a", name: "a_b")) }
        expectError("PC2 has no DNS server configured") { try rt.handle(.nslookup(node: "b", name: "srv1.lab")) }
        #expect(rt.snapshot().nodes[1].dhcpServer?.start == "10.0.0.100")
    }

    @Test func renewsOnRequestAndRestartsDhcpAfterAPowerCycle() throws {
        let rt = try servicesRuntime()
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        runFor(rt, wallMs: 2_000)
        try rt.handle(.renewDhcp(node: "a"))
        runFor(rt, wallMs: 100)
        #expect(rt.snapshot().nodes[2].dhcpClient?.leaseS == 86_400) // renewed at 2 s: a full lease again
        try rt.handle(.setPower(id: "a", on: false))
        #expect(rt.snapshot().nodes[2].ifaces[0].cidr == nil)
        #expect(rt.snapshot().nodes[2].dhcpClient?.state == "INIT")
        try rt.handle(.setPower(id: "a", on: true))
        runFor(rt, wallMs: 100)
        #expect(rt.snapshot().nodes[2].ifaces[0].cidr == "10.0.0.100/24")
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .static))
        runFor(rt, wallMs: 100)
        #expect(rt.snapshot().nodes[1].leases.isEmpty) // released
        #expect(rt.snapshot().nodes[2].dhcpClient == nil)
        #expect(rt.snapshot().nodes[2].ifaces[0].mode == .static)
    }

    @Test func aRemovedHostStopsItsDhcpClient() throws {
        let rt = try servicesRuntime()
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        try rt.handle(.removeNode(id: "srv")) // no server: PC1 keeps retransmitting
        runFor(rt, wallMs: 100)
        let before = rt.snapshot().eventCount
        try rt.handle(.removeNode(id: "a"))
        try rt.handle(.setSpeed(100))
        runFor(rt, wallMs: 1_000) // 100 s simulated: several DISCOVERs if the client were still alive
        #expect(rt.events(from: before).allSatisfy { $0.node != "a" })
    }

    @Test func loadsServicesAndModesAndOpensOlderFilesWithDefaults() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "srv", kind: .server, name: "SRV1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: "10.0.0.2/24")],
                         routes: [], dhcp: DhcpConfig(start: "10.0.9.100", end: "10.0.9.199"), dns: [DnsRecord(name: "srv1.lab", ip: "10.0.0.2")]),
            TopologyNode(id: "a", kind: .pc, name: "PC1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: nil, mode: .dhcp)],
                         routes: [], nameServer: "10.0.0.2"),
        ], links: [LinkView(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "srv", iface: "eth0"))])
        let rt = Runtime()
        try rt.handle(.load(t))
        let s = rt.snapshot()
        #expect(s.nodes[0].dhcpServer?.start == "10.0.9.100") // restored although outside the current subnet
        #expect(s.nodes[0].dnsRecords?.count == 1)
        #expect(s.nodes[1].ifaces[0].mode == .dhcp && s.nodes[1].nameServer == "10.0.0.2")
        let old = #"{"id":"a","kind":"pc","name":"PC1","pos":{"x":0,"y":0},"ifaces":[{"name":"eth0","cidr":null}],"routes":[]}"#
        let node = try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8))
        #expect(node.ifaces[0].mode == .static && node.dhcp == nil && node.dns == nil && node.nameServer == nil)
    }
}
