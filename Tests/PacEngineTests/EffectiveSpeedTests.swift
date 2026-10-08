import Testing
@testable import PacEngine

/// Two switches cabled twice and a PC asking ARP into them: a broadcast storm that uses up every tick's event budget.
private func storm() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "s1", kind: .switch, name: "SW1"))
    try rt.handle(.addNode(id: "s2", kind: .switch, name: "SW2"))
    try rt.handle(.connect(id: "x", a: IfaceRef(node: "s1", iface: "Gi0/1"), b: IfaceRef(node: "s2", iface: "Gi0/1")))
    try rt.handle(.connect(id: "y", a: IfaceRef(node: "s1", iface: "Gi0/2"), b: IfaceRef(node: "s2", iface: "Gi0/2")))
    try rt.handle(.connect(id: "z", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s1", iface: "Gi0/3")))
    try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
    try rt.handle(.ping(node: "a", target: "10.0.0.9"))
    return rt
}

@Suite struct EffectiveSpeedTests {
    @Test func aStormReportsTheSpeedActuallyReached() throws {
        let rt = try storm()
        for _ in 0..<3 { rt.advance(wallMs: 100) }
        let s = rt.snapshot()
        #expect(s.speed == 1 && s.effectiveSpeed < 1 && s.effectiveSpeed >= 0)
    }

    @Test func anIdleOrPausedClockKeepsTheChosenSpeed() throws {
        let idle = Runtime()
        try idle.handle(.setSpeed(5))
        idle.advance(wallMs: 50)
        #expect(idle.snapshot().effectiveSpeed == 5)
        let rt = try storm()
        for _ in 0..<3 { rt.advance(wallMs: 100) }
        try rt.handle(.setRunning(false))
        let paused = rt.snapshot()
        #expect(paused.effectiveSpeed == 1)
        rt.advance(wallMs: 100)
        #expect(rt.snapshot().version == paused.version) // nothing moves while paused
    }
}
