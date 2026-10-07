import Testing
@testable import PacEngine

private func pair(_ opts: LinkOptions = LinkOptions()) throws -> (sim: Sim, a: Probe, b: Probe, link: Link) {
    let sim = Sim()
    let a = Probe(sim: sim, id: "A")
    let b = Probe(sim: sim, id: "B")
    let link = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"), opts)
    return (sim, a, b, link)
}

@Suite struct EventLogTests {
    @Test func keepsTheMostRecentEventsInOrderOnceFull() {
        let log = EventLog(capacity: 3)
        for t in 0..<5 { log.push(SimEvent(time: t, kind: .tx, node: "A")) }
        #expect(log.size == 3)
        #expect(log.total == 5)
        #expect(log.all.map { $0.time } == [2, 3, 4])
        #expect(log.all.map { $0.seq } == [2, 3, 4])
    }

    @Test func readsEventsBySequenceNumberAcrossTheRingWrap() {
        let log = EventLog(capacity: 3)
        for t in 0..<5 { log.push(SimEvent(time: t, kind: .tx, node: "A")) }
        #expect(log.since(0).map(\.seq) == [2, 3, 4])
        #expect(log.since(4).map(\.time) == [4])
        #expect(log.since(5).isEmpty)
        #expect(log.event(1) == nil)
        #expect(log.event(3)?.time == 3)
    }
}

@Suite struct LinkTests {
    @Test func firstFrameArrivesAfter672Plus500NsAndTheNextBackToBack() throws {
        let (sim, a, b, _) = try pair()
        try a.sendRaw()
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.map { $0.time } == [1172, 1844])
        let first = try #require(sim.log.all.first)
        #expect(first.kind == .tx && first.node == "A" && first.iface == "eth0" && first.time == 0)
    }

    @Test func tailDropsWhenTheQueueIsFull() throws {
        let (sim, a, b, _) = try pair(LinkOptions(queueLimit: 2))
        for _ in 0..<5 { try a.sendRaw() }
        sim.run(MS)
        #expect(b.got.count == 3)
        #expect(drops(sim, .queueFull) == 2)
    }

    @Test func dropsLostFramesAtTheReceiver() throws {
        let (sim, a, b, _) = try pair(LinkOptions(lossRate: 1))
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.isEmpty)
        #expect(drops(sim, .loss) == 1)
    }

    @Test func dropsWhenTheLinkInterfaceOrCableIsMissingOrDown() throws {
        let (sim, a, _, link) = try pair()
        link.up = false
        try a.sendRaw()
        try a.iface("eth0").up = false
        try a.sendRaw()
        let lonely = Probe(sim: sim, id: "C")
        try lonely.sendRaw()
        sim.run(MS)
        #expect(drops(sim, .linkDown) == 1)
        #expect(drops(sim, .ifaceDown) == 1)
        #expect(drops(sim, .noLink) == 1)
    }

    @Test func neverTransmitsAFrameInZeroTime() throws {
        let (sim, a, b, _) = try pair(LinkOptions(bandwidthBps: 1e15, propDelayNs: 0))
        try a.sendRaw()
        sim.run(MS)
        #expect(try #require(b.got.first).time > 0)
    }

    @Test func rejectsInvalidLinkOptions() throws {
        let invalid = [LinkOptions(bandwidthBps: 0), LinkOptions(propDelayNs: -5), LinkOptions(lossRate: 1.5),
                       LinkOptions(lossRate: -0.1), LinkOptions(queueLimit: -1), LinkOptions(bandwidthBps: .nan), LinkOptions(bandwidthBps: 0.5)]
        for opts in invalid {
            let sim = Sim()
            let a = Probe(sim: sim, id: "A")
            let b = Probe(sim: sim, id: "B")
            expectError("Invalid link options") { _ = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"), opts) }
            #expect(try a.iface("eth0").link == nil)
        }
    }

    @Test func updatesOptionsForLaterFramesAndValidatesThem() throws {
        let (sim, a, b, link) = try pair()
        try link.update(LinkOptions(bandwidthBps: 1e6, propDelayNs: 1 * MS))
        try a.sendRaw()
        sim.run(10 * MS)
        #expect(b.got.map(\.time) == [672_000 + 1 * MS]) // 84 wire bytes at 1 Mb/s + 1 ms
        expectError("loss rate") { try link.update(LinkOptions(lossRate: 2)) }
        expectError("propagation delay") { try link.update(LinkOptions(propDelayNs: 11 * S)) }
        expectError("bandwidth") { try link.update(LinkOptions(bandwidthBps: .infinity * 0)) }
        #expect(link.opts == LinkOptions(bandwidthBps: 1e6, propDelayNs: 1 * MS))
    }

    @Test func refusesSelfLinksAndDoubleConnections() throws {
        let (sim, a, b, _) = try pair()
        let c = Probe(sim: sim, id: "C")
        a.addInterface("eth1")
        expectError("itself") { _ = try Link(sim: sim, try a.iface("eth1"), try a.iface("eth0")) }
        expectError("already connected") { _ = try Link(sim: sim, try c.iface("eth0"), try b.iface("eth0")) }
    }

    @Test func disconnectFreesBothInterfacesAndLaterFramesFindNoCable() throws {
        let (sim, a, b, link) = try pair()
        link.disconnect()
        #expect(try a.iface("eth0").link == nil)
        #expect(try b.iface("eth0").link == nil)
        try a.sendRaw()
        sim.run(MS)
        #expect(drops(sim, .noLink) == 1)
        let c = Probe(sim: sim, id: "C")
        _ = try Link(sim: sim, try a.iface("eth0"), try c.iface("eth0"))
    }

    @Test func framesOnTheWireOrQueuedWhenTheCableIsPulledNeverArrive() throws {
        let (sim, a, b, link) = try pair()
        try a.sendRaw()
        try a.sendRaw()
        link.disconnect()
        sim.run(MS)
        #expect(b.got.isEmpty)
        #expect(sim.log.all.filter { $0.kind == .tx }.count == 1)
    }
}
