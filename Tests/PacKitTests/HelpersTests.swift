import CoreGraphics
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

    @Test func formatsSimulatedTimeToTheNanosecond() {
        #expect(formatSimTime(0) == "0.000000000 s")
        #expect(formatSimTime(1_000_002_672) == "1.000002672 s")
    }

    @Test func filtersEventsByProtocolAndNode() {
        let e = { (id: Int, node: String, p: Proto) in
            EventView(id: id, timeNs: 0, kind: .tx, node: node, iface: "eth0", proto: p, frameId: id, bytes: 42, info: "", reason: nil)
        }
        let all = [e(0, "a", .arp), e(1, "b", .icmp), e(2, "a", .icmp)]
        #expect(filterEvents(all, protos: [.icmp], node: nil).map(\.id) == [1, 2])
        #expect(filterEvents(all, protos: Set(Proto.allCases), node: "a").map(\.id) == [0, 2])
    }

    @Test func animatesAFrameFromTxUntilItArrivesAndForAtLeastTheFlightTime() {
        let links = [LinkView(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "b", iface: "eth0"))]
        let tx = EventView(id: 0, timeNs: 0, kind: .tx, node: "a", iface: "eth0", proto: .icmp, frameId: 7, bytes: 98, info: "", reason: nil)
        let rx = EventView(id: 1, timeNs: 1172, kind: .rx, node: "b", iface: "eth0", proto: .icmp, frameId: 7, bytes: 98, info: "", reason: nil)
        var f = updateFlights([], with: [tx], links: links, now: 0)
        #expect(f.map(\.from) == ["a"] && !f[0].arrived)
        #expect(flightProgress(f[0], now: 0.2) == 0.5)
        #expect(flightProgress(f[0], now: 9) == 1)
        #expect(pruneFlights(f, links: links, now: 0.7).count == 1) // still on the wire: waits for the next step
        #expect(pruneFlights(f, links: links, now: 0.8).isEmpty) // its rx never came (pull cap, evicted): do not animate forever
        f = updateFlights(f, with: [rx], links: links, now: 0.1)
        #expect(f.count == 1 && f[0].arrived)
        #expect(pruneFlights(f, links: links, now: 0.5).isEmpty)
        #expect(pruneFlights(f, links: [], now: 0.1).isEmpty) // cable removed
    }

    @Test func parsesAndFormatsLinkFields() throws {
        let o = LinkOptions()
        #expect(LinkField.allCases.map { $0.format(o) } == ["1000", "0.5", "0", "1000"])
        #expect(try LinkField.bandwidth.apply(" 0,1 ", to: o).bandwidthBps == 100_000)
        #expect(try LinkField.delay.apply("2.5", to: o).propDelayNs == 2_500)
        #expect(abs(try LinkField.loss.apply("1.1", to: o).lossRate - 0.011) < 1e-12)
        #expect(LinkField.loss.format(try LinkField.loss.apply("1.1", to: o)) == "1.1")
        for bad in ["abc", "", "nan", "inf", "1e300"] {
            expectError("Invalid number") { _ = try LinkField.delay.apply(bad, to: o) }
        }
        expectError("Invalid number") { _ = try LinkField.queue.apply("2.5", to: o) }
    }

    @Test func formatsBandwidthWithUnits() {
        #expect(formatBandwidth(1e9) == "1 Gb/s")
        #expect(formatBandwidth(10e6) == "10 Mb/s")
        #expect(formatBandwidth(1_500) == "1.5 kb/s")
        #expect(formatBandwidth(64) == "64 b/s")
    }

    @Test func formatsTheLatestFlowAndCableMetrics() {
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 9_492_848, delayNs: 1_234_567, jitterNs: nil, lossPct: 1.5))
            == "9.49 Mb/s · RTT 1.235 ms · perdita 1.5%")
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 1_011_360, delayNs: 1_229_300, jitterNs: 2_600, lossPct: 0))
            == "1.01 Mb/s · latenza 1.229 ms · jitter 0.003 ms · perdita 0.0%")
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 0, delayNs: nil, jitterNs: nil, lossPct: 0)) == "0.00 Mb/s · perdita 0.0%")
        #expect(directionSummary(DirectionSample(utilization: 0.946, queued: 12, drops: 3)) == "95% · coda 12 · drop 3")
    }

    @Test func exportFramesEveryDeviceBoxWithAMargin() {
        #expect(exportBounds([], nodeSize: CGSize(width: 104, height: 46), margin: 40) == nil)
        let r = exportBounds([Pos(x: 100, y: 100), Pos(x: 300, y: 200)], nodeSize: CGSize(width: 104, height: 46), margin: 40)
        #expect(r == CGRect(x: 8, y: 37, width: 384, height: 226))
    }
}
