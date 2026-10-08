import Testing
@testable import PacEngine

private func star(_ sim: Sim, _ device: Node, _ names: [String]) throws -> [Probe] {
    try names.enumerated().map { i, name in
        let p = Probe(sim: sim, id: name)
        _ = try Link(sim: sim, try p.iface("eth0"), device.interfaces[i])
        return p
    }
}

@Suite struct L2Tests {
    @Test func hubRepeatsEveryFrameToAllOtherConnectedPorts() throws {
        let sim = Sim()
        let hub = Hub(sim: sim, id: "HUB")
        let probes = try star(sim, hub, ["A", "B", "C"])
        try probes[0].sendRaw(try probes[1].iface("eth0").mac)
        sim.run(MS)
        #expect(probes.map { $0.got.count } == [0, 1, 1])
    }

    @Test func switchFloodsUnknownDestinationsThenForwardsLearnedOnes() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B", "C"])
        try p[0].sendRaw()
        sim.run(MS)
        #expect(p[1].got.count == 1 && p[2].got.count == 1)
        #expect(sw.lookup(try p[0].iface("eth0").mac) === (try sw.iface("Gi0/1")))
        try p[1].sendRaw(try p[0].iface("eth0").mac)
        sim.run(MS)
        #expect(p[0].got.count == 1)
        #expect(p[2].got.count == 1)
        #expect(sw.lookup(try p[1].iface("eth0").mac) === (try sw.iface("Gi0/2")))
    }

    @Test func switchAgesOutMacEntriesAfter300Seconds() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B"])
        try p[0].sendRaw()
        sim.run(MS)
        sim.run(301 * S)
        #expect(sw.lookup(try p[0].iface("eth0").mac) == nil)
    }

    @Test func staysBoundedInALayer2Loop() throws {
        let sim = Sim(logCapacity: 1000)
        let sw1 = Switch(sim: sim, id: "SW1")
        let sw2 = Switch(sim: sim, id: "SW2")
        _ = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
        _ = try Link(sim: sim, try sw1.iface("Gi0/2"), try sw2.iface("Gi0/2"))
        let a = Probe(sim: sim, id: "A")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
        try a.sendRaw()
        sim.run(10 * MS)
        #expect(sim.log.size == 1000)
        #expect(sim.log.total > 1000)
    }

    @Test func listsTheMacTableWithoutAgedEntries() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B"])
        try p[0].sendRaw()
        sim.run(MS)
        #expect(sw.macTable().map { "\($0.mac) \($0.iface)" } == ["\(try p[0].iface("eth0").mac) Gi0/1"])
        sim.run(301 * S)
        #expect(sw.macTable().isEmpty)
    }

    @Test func warnsOncePerSwitchAboutALayer2Loop() throws {
        let sim = Sim(logCapacity: 1000)
        let sw1 = Switch(sim: sim, id: "SW1")
        let sw2 = Switch(sim: sim, id: "SW2")
        _ = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
        _ = try Link(sim: sim, try sw1.iface("Gi0/2"), try sw2.iface("Gi0/2"))
        let a = Probe(sim: sim, id: "A")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
        try a.sendRaw()
        sim.run(10 * MS)
        #expect(Set(sim.warnings.map(\.node)) == ["SW1", "SW2"])
        #expect(sim.warnings.count == 2)
        #expect(sim.warnings.map(\.id).sorted() == [1, 2])
    }

    @Test func aTreeNeverWarns() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B", "C"])
        try p[0].sendRaw()
        try p[1].sendRaw()
        sim.run(MS)
        #expect(sim.warnings.isEmpty)
    }

    @Test func powerResetForgetsTheMacTable() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B"])
        try p[0].sendRaw()
        sim.run(MS)
        sw.reset()
        #expect(sw.macTable().isEmpty)
    }
}
