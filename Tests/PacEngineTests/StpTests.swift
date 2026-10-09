import Testing
@testable import PacEngine

/// "Gi0/1 root forwarding" for each port of `sw`'s tree of `vlan`.
private func tree(_ sw: Switch, _ vlan: Int = 1) -> [String] {
    sw.stp[vlan]?.rows.map { "\($0.port) \($0.role.rawValue) \($0.state.rawValue)" } ?? []
}

/// "<time ns> VLAN 1: blocking → listening" for each state change of `port`.
private func changes(_ sim: Sim, _ node: String, _ port: String) -> [String] {
    sim.log.all.filter { $0.kind == .state && $0.node == node && $0.iface == port }.map { "\($0.time) \($0.note ?? "")" }
}

/// "<node> <port>" of every TCN sent since `since`.
func tcns(_ sim: Sim, since: Int) -> [String] {
    sim.log.all.filter { $0.kind == .tx && $0.time >= since && $0.frame?.payload == .bpdu(.tcn) }.map { "\($0.node) \($0.iface ?? "")" }
}

/// Configuration BPDUs `node` sent since `since`.
private func configs(_ sim: Sim, _ node: String, since: Int) -> [StpConfig] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node, e.time >= since, case .bpdu(.config(let c))? = e.frame?.payload else { return nil }
        return c
    }
}

/// SW1 (the root: lowest MAC) and SW2 cabled twice (Gi0/1, Gi0/2); probe A on SW1 Gi0/3, B on SW2 Gi0/3.
func twoCables(_ sim: Sim) throws -> (sw1: Switch, sw2: Switch, l1: Link, a: Probe, b: Probe) {
    let sw1 = Switch(sim: sim, id: "SW1")
    let sw2 = Switch(sim: sim, id: "SW2")
    let l1 = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
    _ = try Link(sim: sim, try sw1.iface("Gi0/2"), try sw2.iface("Gi0/2"))
    let a = Probe(sim: sim, id: "A")
    let b = Probe(sim: sim, id: "B")
    _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
    _ = try Link(sim: sim, try b.iface("eth0"), try sw2.iface("Gi0/3"))
    return (sw1, sw2, l1, a, b)
}

/// The spec's triangle: SW1 Gi0/1 — SW2 Gi0/1, SW1 Gi0/2 — SW3 Gi0/1 (`sw13`), SW2 Gi0/2 — SW3 Gi0/2.
private func triangle(_ sim: Sim, sw13: LinkOptions = LinkOptions()) throws
    -> (sw1: Switch, sw2: Switch, sw3: Switch, l12: Link, l13: Link, l23: Link) {
    let sw = (1...3).map { Switch(sim: sim, id: "SW\($0)") }
    let l12 = try Link(sim: sim, try sw[0].iface("Gi0/1"), try sw[1].iface("Gi0/1"))
    let l13 = try Link(sim: sim, try sw[0].iface("Gi0/2"), try sw[2].iface("Gi0/1"), sw13)
    let l23 = try Link(sim: sim, try sw[1].iface("Gi0/2"), try sw[2].iface("Gi0/2"))
    return (sw[0], sw[1], sw[2], l12, l13, l23)
}

@Suite struct StpTests {
    @Test func pathCostsAre8021D1998BandsRoundedDown() {
        #expect([1e6, 10e6, 99e6, 100e6, 999e6, 1e9, 9e9, 10e9, 40e9].map(stpCost) == [100, 100, 100, 19, 19, 4, 4, 2, 2])
    }

    @Test func aNewPortGoesBlockingListeningLearningForwardingFifteenSecondsApart() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let a = Probe(sim: sim, id: "A")
        sim.run(5 * S)
        let t = sim.now
        _ = try Link(sim: sim, try a.iface("eth0"), try sw.iface("Gi0/1"))
        sim.run(31 * S)
        #expect(changes(sim, "SW1", "Gi0/1") == ["\(t) VLAN 1: disabled → blocking", "\(t) VLAN 1: blocking → listening",
                                                 "\(t + 15 * S) VLAN 1: listening → learning", "\(t + 30 * S) VLAN 1: learning → forwarding"])
        #expect(tree(sw) == ["Gi0/1 designated forwarding"])
    }

    @Test func dataWaitsForForwardingAndLearningAlreadyFillsTheMacTable() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let a = Probe(sim: sim, id: "A")
        let b = Probe(sim: sim, id: "B")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw.iface("Gi0/1"))
        _ = try Link(sim: sim, try b.iface("eth0"), try sw.iface("Gi0/2"))
        try a.sendRaw() // listening: dropped, not learned
        sim.run(20 * S)
        #expect(sw.macTable().isEmpty)
        try a.sendRaw() // learning: dropped, learned
        sim.run(MS)
        #expect(b.got.isEmpty && drops(sim, .stpDiscarding) == 2)
        #expect(sw.macTable().map(\.iface) == ["Gi0/1"])
        sim.run(11 * S)
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.count == 1)
    }

    @Test func twoSwitchesCabledTwiceBlockOnePortAndABroadcastCrossesOnce() throws {
        let sim = Sim()
        let (sw1, sw2, _, a, b) = try twoCables(sim)
        sim.run(31 * S)
        #expect(tree(sw1) == ["Gi0/1 designated forwarding", "Gi0/2 designated forwarding", "Gi0/3 designated forwarding"])
        #expect(tree(sw2) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking", "Gi0/3 designated forwarding"])
        let hellos = sim.log.all.filter { $0.kind == .tx && $0.node == "SW1" && $0.iface == "Gi0/1" && (10 * S..<20 * S).contains($0.time) }
        #expect(hellos.count == 5 && hellos.allSatisfy { $0.frame?.dst == SSTP_MAC && $0.frame?.vlan == nil })
        let relayed = configs(sim, "SW2", since: 10 * S).first
        #expect(relayed?.root == sw1.stp[1]?.bridge && relayed?.cost == 4 && relayed?.messageAge == 1 && relayed?.port == 0x8003)
        try a.sendRaw()
        sim.run(S)
        #expect(b.got.count == 1)
        #expect(sim.warnings.isEmpty)
    }

    @Test func aTriangleElectsTheLowestBridgeAndBlocksTheFarEndOfTheTie() throws {
        let sim = Sim()
        let (sw1, sw2, sw3, _, _, _) = try triangle(sim)
        sim.run(31 * S)
        #expect(sw1.stp[1]?.isRoot == true)
        #expect(tree(sw1) == ["Gi0/1 designated forwarding", "Gi0/2 designated forwarding"])
        #expect(tree(sw2) == ["Gi0/1 root forwarding", "Gi0/2 designated forwarding"])
        #expect(tree(sw3) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking"])
        #expect(sw3.stp[1]?.root == sw1.stp[1]?.bridge && sw3.stp[1]?.rootCost == 4)
    }

    @Test func aSlowerCableMovesTheRootPort() throws {
        let sim = Sim()
        let (_, sw2, sw3, _, _, _) = try triangle(sim, sw13: LinkOptions(bandwidthBps: 100e6))
        sim.run(31 * S)
        #expect(tree(sw3) == ["Gi0/1 blocked blocking", "Gi0/2 root forwarding"])
        #expect(sw3.stp[1]?.rootCost == 8)
        #expect(tree(sw2) == ["Gi0/1 root forwarding", "Gi0/2 designated forwarding"])
    }

    @Test func whenTheRootPortFailsTheBlockedPortForwardsAfter30Seconds() throws {
        let sim = Sim()
        let (_, sw2, l1, a, b) = try twoCables(sim)
        sim.run(41 * S)
        let t = sim.now
        l1.up = false
        #expect(tree(sw2) == ["Gi0/2 root listening", "Gi0/3 designated forwarding"])
        sim.run(30 * S)
        #expect(changes(sim, "SW2", "Gi0/2").suffix(3) == ["\(t) VLAN 1: blocking → listening", "\(t + 15 * S) VLAN 1: listening → learning",
                                                           "\(t + 30 * S) VLAN 1: learning → forwarding"])
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.count == 1)
    }

    @Test func anIndirectFailureWaitsForMaxAgeBeforeTheBlockedPortStartsOver() throws {
        let sim = Sim()
        let (sw1, sw2, sw3, l12, _, _) = try triangle(sim)
        let a = Probe(sim: sim, id: "A")
        let b = Probe(sim: sim, id: "B")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
        _ = try Link(sim: sim, try b.iface("eth0"), try sw2.iface("Gi0/3"))
        sim.run(41 * S)
        let t = sim.now
        l12.up = false
        sim.run(17 * S)
        #expect(tree(sw3).contains("Gi0/2 blocked blocking")) // SW2's claims to be root are worse than what the port holds
        sim.run(28 * S)
        #expect(tree(sw3).contains("Gi0/2 designated learning"))
        sim.run(5 * S)
        let last = sim.log.all.last { $0.kind == .state && $0.node == "SW3" && $0.iface == "Gi0/2" }
        #expect(last?.note == "VLAN 1: learning → forwarding")
        // Max age counts from the last BPDU minus its message age (1 s, one bridge away): 48–50 s, as on IOS without BackboneFast.
        #expect((t + 47 * S..<t + 50 * S).contains(last?.time ?? 0))
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.count == 1)
    }

    @Test func aTopologyChangeShortensMacAgingTo15SecondsForMaxAgePlusForwardDelay() throws {
        let sim = Sim()
        let (sw1, sw2, l1, a, _) = try twoCables(sim)
        sim.run(70 * S) // past the change of the first convergence
        try a.sendRaw()
        sim.run(10 * S)
        #expect(sw1.stp[1]?.topologyChange == false && sw1.macTable().map(\.iface) == ["Gi0/3"])
        let t = sim.now
        l1.up = false
        sim.run(4 * S)
        #expect(sw2.stp[1]?.topologyChange == true)
        #expect(tcns(sim, since: t) == ["SW2 Gi0/2"]) // one TCN, acknowledged at once
        #expect(configs(sim, "SW1", since: t).contains { $0.tc && $0.tca })
        sim.run(13 * S) // A's entry is 27 s old: gone after 15 s instead of 300 s
        #expect(sw1.macTable().isEmpty)
        sim.run(21 * S) // t + 38 s: Gi0/2 of SW2 turned forwarding at t + 30 s, a second change: TC lasts until t + 65 s
        #expect(sw1.stp[1]?.topologyChange == true)
        sim.run(30 * S) // the root clears TC at t + 65 s, SW2 with the next BPDU
        #expect(sw1.stp[1]?.topologyChange == false && sw2.stp[1]?.topologyChange == false)
    }

    @Test func aPortMovedToAnotherVlanLeavesItsTreeAndStartsOverInTheNewOne() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let a = Probe(sim: sim, id: "A")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw.iface("Gi0/1"))
        sim.run(31 * S)
        let t = sim.now
        try sw.setSwitchport("Gi0/1", PortConfig(vlan: 10))
        #expect(changes(sim, "SW1", "Gi0/1").filter { $0.hasPrefix("\(t) ") } == [
            "\(t) VLAN 1: forwarding → disabled", "\(t) VLAN 10: disabled → blocking", "\(t) VLAN 10: blocking → listening",
        ])
        #expect(sw.stp.keys.sorted() == [10]) // no up port carries VLAN 1 any more
    }

    /// No VLAN database (spec M7 §2): VLAN 10, used by access ports on SW1 and SW3 only, runs on SW2's trunks too and its loop is broken.
    @Test func aSwitchWithOnlyTrunksRunsTheTreeOfEveryVlanItCarries() throws {
        let sim = Sim()
        let (sw1, sw2, sw3, _, _, _) = try triangle(sim)
        for sw in [sw1, sw2, sw3] {
            for port in ["Gi0/1", "Gi0/2"] { try sw.setSwitchport(port, PortConfig(mode: .trunk)) }
        }
        try sw1.setSwitchport("Gi0/3", PortConfig(vlan: 10))
        try sw3.setSwitchport("Gi0/3", PortConfig(vlan: 10))
        let a = Probe(sim: sim, id: "A")
        let c = Probe(sim: sim, id: "C")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
        _ = try Link(sim: sim, try c.iface("eth0"), try sw3.iface("Gi0/3"))
        sim.run(31 * S)
        #expect(sw2.stp.keys.sorted() == [1, 10])
        #expect(tree(sw3, 10) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking", "Gi0/3 designated forwarding"])
        try a.sendRaw()
        sim.run(S)
        #expect(c.got.count == 1 && sim.warnings.isEmpty)
    }

    @Test func neighboursSeeASwitchPoweredOffAtOnceAndItStartsOverWhenPoweredOn() throws {
        let sim = Sim()
        let (sw1, sw2, sw3, _, _, _) = try triangle(sim)
        sim.run(31 * S)
        sw2.powered = false // as Runtime's setPower does
        sw2.reset()
        #expect(sw2.stp.isEmpty)
        #expect(tree(sw1) == ["Gi0/2 designated forwarding"])
        #expect(tree(sw3) == ["Gi0/1 root forwarding"])
        sw2.powered = true
        sw2.powerOn()
        #expect(tree(sw1) == ["Gi0/1 designated listening", "Gi0/2 designated forwarding"])
        sim.run(31 * S)
        #expect(tree(sw2) == ["Gi0/1 root forwarding", "Gi0/2 designated forwarding"])
        #expect(tree(sw3) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking"])
    }

    @Test func aPortFastPortForwardsAtOnceAndNeverSendsATcn() throws {
        let sim = Sim()
        let sw1 = Switch(sim: sim, id: "SW1")
        let sw2 = Switch(sim: sim, id: "SW2")
        _ = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
        try sw2.setSwitchport("Gi0/2", PortConfig(portfast: true))
        try sw2.setSwitchport("Gi0/5", PortConfig(mode: .trunk, portfast: true)) // PortFast acts on access ports only
        sim.run(31 * S)
        let t = sim.now
        let a = Probe(sim: sim, id: "A")
        let c = Probe(sim: sim, id: "C")
        let d = Probe(sim: sim, id: "D")
        let fast = try Link(sim: sim, try a.iface("eth0"), try sw2.iface("Gi0/2"))
        _ = try Link(sim: sim, try c.iface("eth0"), try sw2.iface("Gi0/4"))
        _ = try Link(sim: sim, try d.iface("eth0"), try sw2.iface("Gi0/5"))
        #expect(tree(sw2) == ["Gi0/1 root forwarding", "Gi0/2 designated forwarding", "Gi0/4 designated listening", "Gi0/5 designated listening"])
        sim.run(5 * S)
        try sw2.setSwitchport("Gi0/4", PortConfig(portfast: true)) // turned on while listening: forwarding at once
        #expect(sw2.stp[1]?.state(try sw2.iface("Gi0/4")) == .forwarding)
        fast.up = false
        sim.run(S)
        fast.up = true
        sim.run(S)
        #expect(tcns(sim, since: t).isEmpty)
        sim.run(30 * S)
        #expect(tcns(sim, since: t) == ["SW2 Gi0/1"]) // Gi0/5, a trunk, went the slow way and announced it
    }

    @Test func eachVlanElectsItsOwnRootAndBlocksItsOwnPort() throws {
        let sim = Sim()
        let sw1 = Switch(sim: sim, id: "SW1")
        let sw2 = Switch(sim: sim, id: "SW2")
        for sw in [sw1, sw2] {
            for port in ["Gi0/1", "Gi0/2"] { try sw.setSwitchport(port, PortConfig(mode: .trunk)) }
            try sw.setSwitchport("Gi0/3", PortConfig(vlan: 10))
            try sw.setSwitchport("Gi0/4", PortConfig(vlan: 20))
        }
        try sw2.setStpPriority(20, 4096)
        _ = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
        _ = try Link(sim: sim, try sw1.iface("Gi0/2"), try sw2.iface("Gi0/2"))
        sim.run(31 * S)
        #expect(sw1.stp.keys.sorted() == [1, 10, 20])
        #expect(sw1.stp[10]?.isRoot == true && sw2.stp[20]?.isRoot == true)
        #expect(sw1.stp[20]?.root.text == "4096/20/\(try sw2.iface("Gi0/1").mac)")
        #expect(tree(sw2, 10) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking"])
        #expect(tree(sw1, 20) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking"])
        let tags = sim.log.all.filter { $0.kind == .tx && $0.node == "SW1" && $0.iface == "Gi0/1" && $0.frame?.dst == SSTP_MAC }.map { $0.frame?.vlan ?? 0 }
        #expect(Set(tags) == [0, 10, 20]) // VLAN 1 is native: untagged
    }

    @Test func aLowerPriorityTakesTheRootAtOnce() throws {
        let sim = Sim()
        let (sw1, sw2, _, _, _) = try twoCables(sim)
        sim.run(31 * S)
        try sw2.setStpPriority(1, 28672)
        #expect(sw2.stp[1]?.isRoot == true)
        sim.run(MS)
        #expect(sw1.stp[1]?.root == sw2.stp[1]?.bridge)
        #expect(tree(sw1) == ["Gi0/1 root forwarding", "Gi0/2 blocked blocking", "Gi0/3 designated forwarding"])
    }

    @Test func refusesPrioritiesThatAreNotMultiplesOf4096() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        for p in [1000, -4096, 65536] {
            expectError("STP priority must be a multiple of 4096 between 0 and 61440") { try rt.handle(.setStpPriority(node: "s", vlan: 10, priority: p)) }
        }
        expectError("VLAN must be between 1 and 4094") { try rt.handle(.setStpPriority(node: "s", vlan: 0, priority: 4096)) }
        expectError("PC1 does not run spanning tree") { try rt.handle(.setStpPriority(node: "a", vlan: 1, priority: 4096)) }
        try rt.handle(.setStpPriority(node: "s", vlan: 10, priority: 0))
    }

    @Test func theSnapshotListsEachVlanTreeAndTheConfiguredPriorities() throws {
        let rt = Runtime()
        for (id, name) in [("s1", "SW1"), ("s2", "SW2")] { try rt.handle(.addNode(id: id, kind: .switch, name: name)) }
        for (id, port) in [("x", "Gi0/1"), ("y", "Gi0/2")] {
            try rt.handle(.connect(id: id, a: IfaceRef(node: "s1", iface: port), b: IfaceRef(node: "s2", iface: port)))
        }
        try rt.handle(.setStpPriority(node: "s2", vlan: 1, priority: 28672))
        for _ in 0..<310 { rt.advance(wallMs: 100) }
        let s = rt.snapshot()
        #expect(s.nodes[1].stpPriorities == [StpPriority(vlan: 1, priority: 28672)] && s.nodes[0].stpPriorities.isEmpty)
        let root = s.nodes[1].stp
        #expect(root.map(\.vlan) == [1] && root[0].priority == 28672 && root[0].rootPort == nil && root[0].cost == 0)
        #expect(root[0].root == "28672/1/\(s.nodes[1].ifaces[0].mac)")
        let other = s.nodes[0].stp[0]
        #expect(other.priority == 32768 && other.rootPort == "Gi0/1" && other.cost == 4 && other.root == root[0].root)
        #expect(other.ports == [StpPortRow(iface: "Gi0/1", role: .root, state: .forwarding), StpPortRow(iface: "Gi0/2", role: .blocked, state: .blocking)])
    }
}
