import Foundation
import Testing
@testable import PacEngine

/// SW1 with SRV1 (10.0.0.2/24, sink on, behind the 10 Mb/s cable l1) and PC1 (10.0.0.1/24, cable l2).
private func trafficRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
    try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "s", iface: "Gi0/1"), b: IfaceRef(node: "srv", iface: "eth0")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2")))
    try rt.handle(.updateLink(id: "l1", options: LinkOptions(bandwidthBps: 10e6)))
    try rt.handle(.setIp(node: "srv", iface: "eth0", cidr: "10.0.0.2/24"))
    try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
    try rt.handle(.setSink(node: "srv", on: true))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

private let GOODPUT_10MB = 9_492_848.0

@Suite struct RuntimeTrafficTests {
    @Test func runsTcpTrafficAndSamplesTheFlowAndEveryCableEvery100ms() throws {
        let rt = try trafficRuntime()
        try rt.handle(.trafficTcp(node: "a", target: " 10.0.0.2 ", bytes: 1_000_000))
        runFor(rt, wallMs: 2_000)
        let s = rt.snapshot()
        let app = s.apps[0]
        #expect(app.title == "iperf3 -c 10.0.0.2 -p 9 -n 1000000" && app.done && app.lines.last == "iperf Done.")
        let cable = try #require(s.linkSamples["l1"])
        #expect(cable.count == 20 && cable.first?.timeNs == 100 * MS && cable.last?.timeNs == 2 * S)
        #expect(cable[3].ab.utilization > 0.95) // SW1 → SRV1 is the 10 Mb/s bottleneck
        #expect(cable[3].ba.utilization < 0.1) // only ACKs come back (84 of every 1538 wire bytes)
        #expect(s.linkSamples["l2"]?.count == 20)
        #expect(abs(app.samples[3].bitsPerSecond - GOODPUT_10MB) / GOODPUT_10MB < 0.05)
        #expect(app.samples.allSatisfy { $0.jitterNs == nil && $0.lossPct == 0 } && app.samples[3].delayNs != nil)
        #expect(s.nodes[1].sink && s.nodes[1].tcp == [TcpRow(local: "0.0.0.0:9", remote: "0.0.0.0:*", state: "LISTEN")])
        #expect(s.nodes[2].tcp.map { "\($0.remote) \($0.state)" } == ["10.0.0.2:9 TIME_WAIT"])
        try rt.handle(.disconnect(id: "l2"))
        #expect(rt.snapshot().linkSamples["l2"] == nil)
        try rt.handle(.load(Topology(seed: 1)))
        #expect(rt.snapshot().linkSamples.isEmpty)
    }

    @Test func aTcpFlowShorterThan100msStillGetsOnePoint() throws {
        let rt = try trafficRuntime()
        try rt.handle(.updateLink(id: "l1", options: LinkOptions())) // 1 Gb/s: 1 MB takes ~9 ms
        try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 1_000_000))
        runFor(rt, wallMs: 1_000)
        let app = rt.snapshot().apps[0]
        #expect(app.done && app.lines.last == "iperf Done.")
        #expect(app.samples.map(\.timeNs) == [100 * MS] && app.samples[0].bitsPerSecond == 80e6) // 1 MB in one 100 ms interval
    }

    @Test func udpAboveTheCableRateFillsTheQueueAndTailDrops() throws {
        let rt = try trafficRuntime()
        try rt.handle(.updateLink(id: "l1", options: LinkOptions(bandwidthBps: 10e6, queueLimit: 10)))
        try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: 20e6, seconds: 1))
        runFor(rt, wallMs: 3_000)
        let s = rt.snapshot()
        let app = s.apps[0]
        #expect(app.title == "iperf3 -u -c 10.0.0.2 -p 9 -b 20000000 -t 1" && app.done)
        #expect(app.lines[2].contains("/1701 (") && !app.lines[2].hasSuffix("(0%)")) // 1701 datagrams, one every 588 µs
        let cable = try #require(s.linkSamples["l1"])
        #expect(cable.map(\.ab.queued).max() == 10) // the queue fills to its limit…
        #expect(cable.reduce(0) { $0 + $1.ab.drops } > 700) // …and drops about half the datagrams
        #expect(app.samples.last!.lossPct > 40 && app.samples.allSatisfy { $0.jitterNs != nil })
    }

    @Test func rejectsBadTrafficSettingsAndSinksOnHosts() throws {
        let rt = try trafficRuntime()
        expectError("Bytes must be between 1 and 1000000000") { try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 0)) }
        expectError("Bitrate must be between 1 kb/s and 1 Gb/s") {
            try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: .nan, seconds: 1))
        }
        expectError("Bitrate must be between") { try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: 2e9, seconds: 1)) }
        expectError("Duration must be between 1 and 3600 s") {
            try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 0))
        }
        expectError("Invalid address or host name") { try rt.handle(.trafficTcp(node: "a", target: "a b", bytes: 10)) }
        expectError("PC1 cannot run a traffic sink") { try rt.handle(.setSink(node: "a", on: true)) }
        expectError("SW1 has no IP stack") { try rt.handle(.trafficTcp(node: "s", target: "10.0.0.2", bytes: 10)) }
        try rt.handle(.setPower(id: "a", on: false))
        expectError("PC1 is powered off") { try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 10)) }
        #expect(rt.snapshot().apps.isEmpty)
    }

    @Test func poweringTheSenderOffEndsItsFlow() throws {
        let rt = try trafficRuntime()
        try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 100_000_000))
        runFor(rt, wallMs: 300)
        try rt.handle(.setPower(id: "a", on: false))
        let s = rt.snapshot()
        #expect(s.apps[0].done && s.apps[0].lines.last == "iperf3: interrupt - the client has terminated")
        #expect(s.nodes[2].tcp.isEmpty)
    }

    @Test func steppingOverAnIdleHalfDayKeepsOnlyTheLastMinuteOfSamples() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "srv", iface: "eth0")))
        try rt.handle(.setIp(node: "srv", iface: "eth0", cidr: "10.0.0.2/24"))
        try rt.handle(.setDhcpServer(node: "srv", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199")))
        try rt.handle(.setMode(.simulation))
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        // DORA takes a handful of steps; then the next logged event is the renewal at T1 = 43 200 s.
        for _ in 0..<100 where rt.snapshot().timeNs < 3600 * S { try rt.handle(.step) }
        let s = rt.snapshot()
        #expect(s.timeNs >= 43_200 * S)
        let series = try #require(s.linkSamples["l"])
        #expect(series.count == 600)
        #expect(zip(series, series.dropFirst()).allSatisfy { $1.timeNs - $0.timeNs == 100 * MS })
        #expect(series.last!.timeNs == (s.timeNs - 1) / (100 * MS) * (100 * MS)) // the last boundary before the event
    }

    @Test func loadsTheSinkAndOpensOlderFilesWithItOff() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "srv", kind: .server, name: "SRV1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: "10.0.0.2/24")],
                         routes: [], sink: true),
        ])
        let rt = Runtime()
        try rt.handle(.load(t))
        #expect(rt.snapshot().nodes[0].sink && rt.snapshot().nodes[0].tcp.map(\.state) == ["LISTEN"])
        let old = #"{"id":"srv","kind":"server","name":"SRV1","pos":{"x":0,"y":0},"ifaces":[],"routes":[]}"#
        #expect(try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8)).sink == false)
    }
}
