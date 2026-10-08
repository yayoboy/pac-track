import Testing
@testable import PacEngine

private func run(_ rt: Runtime, seconds: Int) {
    for _ in 0..<(seconds * 10) { rt.advance(wallMs: 100) }
}

/// PC1 (192.168.1.10/24, DNS 8.8.8.8) — R1 (Gi0/0 192.168.1.1/24 inside, Gi0/1 203.0.113.2/24 outside, default via 203.0.113.1)
/// — ISP1 (Gi0/0 203.0.113.1/24, DNS www.example.com → 198.51.100.10).
private func cloudLab() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "pc", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r1", kind: .router, name: "R1"))
    try rt.handle(.addNode(id: "isp", kind: .cloud, name: "ISP1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "pc", iface: "eth0"), b: IfaceRef(node: "r1", iface: "Gi0/0")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "r1", iface: "Gi0/1"), b: IfaceRef(node: "isp", iface: "Gi0/0")))
    for (node, iface, cidr) in [("pc", "eth0", "192.168.1.10/24"), ("r1", "Gi0/0", "192.168.1.1/24"), ("r1", "Gi0/1", "203.0.113.2/24"),
                                ("isp", "Gi0/0", "203.0.113.1/24")] {
        try rt.handle(.setIp(node: node, iface: iface, cidr: cidr))
    }
    try rt.handle(.addRoute(node: "pc", cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
    try rt.handle(.addRoute(node: "r1", cidr: "0.0.0.0/0", nextHop: "203.0.113.1"))
    try rt.handle(.setNat(node: "r1", config: NatConfig(inside: ["Gi0/0"], outside: "Gi0/1")))
    try rt.handle(.setDnsServer(node: "isp", records: [DnsRecord(name: "www.example.com", ip: "198.51.100.10")]))
    try rt.handle(.setNameServer(node: "pc", ip: "8.8.8.8"))
    return rt
}

@Suite struct CloudTests {
    @Test func theInternetAnswersPingAndDnsFromAnyPublicAddress() throws {
        let rt = try cloudLab()
        #expect(rt.snapshot().nodes[2].kind == .cloud && rt.snapshot().nodes[2].ifaces.count == 4)
        try rt.handle(.ping(node: "pc", target: "8.8.8.8"))
        try rt.handle(.nslookup(node: "pc", name: "www.example.com"))
        run(rt, seconds: 6)
        try rt.handle(.ping(node: "pc", target: "www.example.com"))
        run(rt, seconds: 6)
        let apps = rt.snapshot().apps
        #expect(apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(apps[0].lines.contains { $0.hasPrefix("64 bytes from 8.8.8.8: icmp_seq=1 ttl=254") })
        #expect(apps[1].lines.contains("Address: 198.51.100.10")) // the answer came from 8.8.8.8, the address asked
        #expect(apps[2].lines.first == "PING www.example.com (198.51.100.10) 56(84) bytes of data.")
        #expect(apps[2].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
    }

    @Test func tracerouteEndsAtTheProbedAddressAndPrivateOrLocalAddressesAreUnreachable() throws {
        let rt = try cloudLab()
        // A subnet of the cloud's own that R1 does not share: its unused addresses are not the Internet.
        try rt.handle(.setIp(node: "isp", iface: "Gi0/1", cidr: "192.0.2.1/24"))
        try rt.handle(.traceroute(node: "pc", target: "198.51.100.10"))
        run(rt, seconds: 15) // ARP caches warm: the pings below are not queued behind the probes (3 packets per address)
        try rt.handle(.ping(node: "pc", target: "10.9.9.9"))
        try rt.handle(.ping(node: "pc", target: "192.0.2.99"))
        run(rt, seconds: 15)
        let apps = rt.snapshot().apps
        #expect(apps[0].done)
        #expect(apps[0].lines[1].hasPrefix(" 1  192.168.1.1 (192.168.1.1)"))
        #expect(apps[0].lines[2].hasPrefix(" 2  198.51.100.10 (198.51.100.10)")) // the port unreachable comes from the address probed
        #expect(apps[1].lines.contains { $0.hasPrefix("From 203.0.113.1 icmp_seq=1 Destination Net Unreachable") }) // private: no route
        #expect(apps[2].lines.contains { $0.hasPrefix("From 203.0.113.1 icmp_seq=1 Destination Host Unreachable") }) // its own subnet, no host
    }
}
