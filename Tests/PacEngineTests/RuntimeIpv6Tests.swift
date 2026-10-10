import Foundation
import Testing
@testable import PacEngine

private func runFor(_ rt: Runtime, ms: Int) {
    for _ in stride(from: 0, to: ms, by: 100) { rt.advance(wallMs: 100) }
}

/// PC1 — R1 Gi0/0, dual stack: PC1 on SLAAC; R1 10.0.1.1/24 and 2001:db8:1::1/64 with `ipv6 unicast-routing` and a static route.
/// MACs: PC1 …:01, R1 Gi0/0 …:02.
private func lab() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
    try rt.handle(.connect(id: "1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0")))
    try rt.handle(.setIp(node: "r", iface: "Gi0/0", cidr: "10.0.1.1/24"))
    try rt.handle(.setIpv6(node: "r", iface: "Gi0/0", config: Ipv6Config(address: "2001:db8:1::1/64")))
    try rt.handle(.setIpv6Routing(node: "r", on: true))
    try rt.handle(.setIpv6(node: "a", iface: "eth0", config: Ipv6Config(autoconfig: true)))
    try rt.handle(.addRoute(node: "r", cidr: " 2001:db8:9::/64", nextHop: "2001:db8:1::99 "))
    return rt
}

@Suite struct RuntimeIpv6Tests {
    @Test func snapshotsShowAddressesRoutesAndNeighbours() throws {
        let rt = try lab()
        #expect(rt.snapshot().nodes[0].ifaces[0].ipv6 == ["fe80::ff:fe00:1/64 · link-local · tentativo"])
        runFor(rt, ms: 3000)
        let s = rt.snapshot()
        let (pc, r) = (s.nodes[0], s.nodes[1])
        #expect(pc.ifaces[0].ipv6Config == Ipv6Config(autoconfig: true))
        #expect(pc.ifaces[0].ipv6 == ["fe80::ff:fe00:1/64 · link-local", "2001:db8:1::ff:fe00:1/64 · SLAAC"])
        #expect(r.ifaces[0].ipv6 == ["fe80::ff:fe00:2/64 · link-local", "2001:db8:1::1/64 · manuale"])
        #expect(r.ifaces[1].ipv6.isEmpty && r.ifaces[1].ipv6Config == nil)
        #expect(pc.routes == [RouteRow(dest: "2001:db8:1::/64", nextHop: nil, iface: "eth0", isStatic: false),
                              RouteRow(dest: "::/0", nextHop: "fe80::ff:fe00:2", iface: "eth0", isStatic: false, ra: true)])
        #expect(r.routes == [RouteRow(dest: "10.0.1.0/24", nextHop: nil, iface: "Gi0/0", isStatic: false),
                             RouteRow(dest: "2001:db8:1::/64", nextHop: nil, iface: "Gi0/0", isStatic: false),
                             RouteRow(dest: "2001:db8:9::/64", nextHop: "2001:db8:1::99", iface: "Gi0/0", isStatic: true)])
        #expect(r.ipv6Routing && !pc.ipv6Routing)
        #expect(pc.neighbors6 == [NeighborRow(addr: "fe80::ff:fe00:2", mac: "02:00:00:00:00:02", state: "STALE", iface: "eth0")])
        try rt.handle(.removeRoute(node: "r", cidr: "2001:db8:9::/64"))
        try rt.handle(.ping(node: "a", target: "2001:db8:1::1"))
        runFor(rt, ms: 4000)
        #expect(rt.snapshot().apps[0].lines.last == "4 packets transmitted, 4 received, 0% packet loss")
        #expect(!rt.snapshot().nodes[1].routes.contains { $0.isStatic })
        try rt.handle(.setIpv6(node: "a", iface: "eth0", config: nil))
        #expect(rt.snapshot().nodes[0].ifaces[0].ipv6.isEmpty && rt.snapshot().nodes[0].neighbors6.isEmpty)
    }

    @Test func refusesWhatIpv6CannotDo() throws {
        let rt = try lab()
        let address = { (text: String) in Command.setIpv6(node: "r", iface: "Gi0/1", config: Ipv6Config(address: text)) }
        let cases: [(Command, String)] = [
            (.setIpv6(node: "r", iface: "Gi0/1", config: Ipv6Config(autoconfig: true)), "R1 cannot use SLAAC: only hosts autoconfigure"),
            (.setIpv6Routing(node: "a", on: true), "PC1 cannot route IPv6"),
            (address("2001:db8:2::5"), "Invalid IPv6 prefix: \"2001:db8:2::5\""),
            (address("2001:db8:2::5/0"), "Invalid IPv6 prefix: \"2001:db8:2::5/0\""),
            (address("2001:db8:zz::1/64"), "Invalid IPv6 address: \"2001:db8:zz::1\""),
            (address("fe80::1/64"), "fe80::1 cannot be assigned: it is unspecified, loopback, multicast or link-local"),
            (address("ff02::5/64"), "ff02::5 cannot be assigned: it is unspecified, loopback, multicast or link-local"),
            (address("::1/128"), "::1 cannot be assigned: it is unspecified, loopback, multicast or link-local"),
            (address("2001:db8:2::/64"), "2001:db8:2::/64 is the Subnet-Router anycast address"),
            (address("2001:db8:1::5/64"), "2001:db8:1::5/64 overlaps with Gi0/0"),
            (.setIpv6(node: "r", iface: "Gi0/9", config: Ipv6Config()), "r has no interface Gi0/9"),
            (.addRoute(node: "r", cidr: "2001:db8:8::/64", nextHop: "fe80::1"), "Next hop fe80::1 is not in a connected IPv6 subnet"),
            (.ping(node: "a", target: "fe80::1"), "Ping to link-local or multicast addresses is not supported"),
            (.traceroute(node: "a", target: "ff02::1"), "Traceroute to link-local or multicast addresses is not supported"),
        ]
        for (cmd, message) in cases { expectError(message) { try rt.handle(cmd) } }
        try rt.handle(address("2001:db8:2::/127")) // RFC 6164: a /127 has no Subnet-Router anycast
    }

    @Test func ipv6SurvivesSavingAndAnM8FileOpensWithIpv6Off() throws {
        let t = Topology(nodes: [
            TopologyNode(id: "a", kind: .pc, name: "PC1", pos: Pos(x: 0, y: 0),
                         ifaces: [TopologyIface(name: "eth0", cidr: nil, ipv6: Ipv6Config(autoconfig: true))], routes: []),
            TopologyNode(id: "r", kind: .router, name: "R1", pos: Pos(x: 0, y: 0),
                         ifaces: [TopologyIface(name: "Gi0/0", cidr: "10.0.1.1/24", ipv6: Ipv6Config(address: "2001:db8:1::1/64"))]
                             + (1...3).map { TopologyIface(name: "Gi0/\($0)", cidr: nil) },
                         routes: [TopologyRoute(cidr: "2001:db8:9::/64", nextHop: "2001:db8:1::99")], ipv6Routing: true),
        ], links: [LinkView(id: "1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0"))])
        let copy = try JSONDecoder().decode(Topology.self, from: try JSONEncoder().encode(t))
        #expect(copy == t)
        let rt = Runtime()
        try rt.handle(.load(copy))
        runFor(rt, ms: 3000)
        let s = rt.snapshot()
        #expect(s.nodes[1].ipv6Routing && s.nodes[1].routes.contains { $0.dest == "2001:db8:9::/64" && $0.isStatic })
        #expect(s.nodes[0].ifaces[0].ipv6.last == "2001:db8:1::ff:fe00:1/64 · SLAAC")
        // A node and an interface written by M8 have no IPv6 keys.
        let old = #"{"id":"a","kind":"pc","name":"PC1","pos":{"x":0,"y":0},"ifaces":[{"name":"eth0","mode":"static"}],"routes":[]}"#
        let node = try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8))
        #expect(!node.ipv6Routing && node.ifaces[0].ipv6 == nil)
    }
}
