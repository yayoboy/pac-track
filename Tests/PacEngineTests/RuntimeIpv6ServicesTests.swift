import Foundation
import Testing
@testable import PacEngine

private func runFor(_ rt: Runtime, ms: Int) {
    for _ in stride(from: 0, to: ms, by: 100) { rt.advance(wallMs: 100) }
}

/// The spec's M9b lab: PC1 — R1 — SRV1, R1 Gi0/0 2001:db8:1::1/64 and Gi0/1 2001:db8:2::1/64 with `ipv6 unicast-routing`, PC1 on
/// SLAAC, SRV1 2001:db8:2::53/64 with the sink. PC1's MAC is …:01, so its address is 2001:db8:1::ff:fe00:1.
private func lab() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
    try rt.handle(.addNode(id: "s", kind: .server, name: "SRV1"))
    try rt.handle(.connect(id: "1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0")))
    try rt.handle(.connect(id: "2", a: IfaceRef(node: "r", iface: "Gi0/1"), b: IfaceRef(node: "s", iface: "eth0")))
    try rt.handle(.setIpv6(node: "r", iface: "Gi0/0", config: Ipv6Config(address: "2001:db8:1::1/64")))
    try rt.handle(.setIpv6(node: "r", iface: "Gi0/1", config: Ipv6Config(address: "2001:db8:2::1/64")))
    try rt.handle(.setIpv6Routing(node: "r", on: true))
    try rt.handle(.setIpv6(node: "a", iface: "eth0", config: Ipv6Config(autoconfig: true)))
    try rt.handle(.setIpv6(node: "s", iface: "eth0", config: Ipv6Config(address: "2001:db8:2::53/64")))
    try rt.handle(.setSink(node: "s", on: true))
    return rt
}

@Suite struct RuntimeIpv6ServicesTests {
    @Test func tcpConnectionsShowIpv6EndsInBrackets() throws {
        let rt = try lab()
        runFor(rt, ms: 3000)
        try rt.handle(.trafficTcp(node: "a", target: "2001:db8:2::53", bytes: 1_000_000_000))
        runFor(rt, ms: 200)
        let s = rt.snapshot()
        let row = s.nodes[0].tcp.first
        #expect(row?.local.hasPrefix("[2001:db8:1::ff:fe00:1]:") == true && row?.remote == "[2001:db8:2::53]:9" && row?.state == "ESTABLISHED")
        #expect(s.nodes[2].tcp.first == TcpRow(local: "0.0.0.0:9", remote: "0.0.0.0:*", state: "LISTEN"))
        #expect(s.apps[0].title == "iperf3 -c 2001:db8:2::53 -p 9 -n 1000000000")
    }
}
