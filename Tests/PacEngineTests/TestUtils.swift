import Testing
@testable import PacEngine

/// Expects `body` to throw an error whose description contains `fragment`.
func expectError(_ fragment: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected an error containing \"\(fragment)\"", sourceLocation: sourceLocation)
    } catch {
        #expect("\(error)".contains(fragment), "got: \(error)", sourceLocation: sourceLocation)
    }
}

/// Minimal node that records every frame it receives and can emit raw frames.
final class Probe: Node {
    var got: [(frame: EthernetFrame, iface: String, time: Int)] = []

    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("eth0")
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        got.append((frame, iface.name, sim.now))
    }

    @discardableResult
    func sendRaw(_ dst: Mac = BROADCAST_MAC) throws -> EthernetFrame {
        let i = try iface("eth0")
        let frame = EthernetFrame(id: sim.nextId(), src: i.mac, dst: dst, etherType: ETHERTYPE_ARP,
                                  payload: .arp(ArpPacket(op: 1, senderMac: i.mac, senderIp: 0, targetMac: "00:00:00:00:00:00", targetIp: 0)))
        i.send(frame)
        return frame
    }
}

func drops(_ sim: Sim, _ reason: DropReason) -> Int {
    sim.log.all.filter { $0.kind == .drop && $0.reason == reason }.count
}

struct Seen: Equatable {
    let from: String
    let type: UInt8
    let code: UInt8
    let ttl: UInt8
}

final class IcmpRecorder {
    var seen: [Seen] = []
}

func icmpSeen(_ node: IpNode) -> IcmpRecorder {
    let recorder = IcmpRecorder()
    node.onIcmp { p, m in recorder.seen.append(Seen(from: formatIp(p.src), type: m.type, code: m.code, ttl: p.ttl)) }
    return recorder
}

func echoRequest(_ length: Int = 56) -> L4 {
    .icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: 9, seq: 1, data: [UInt8](repeating: 0, count: length)))
}

/// A (10.0.0.1/24) and B (10.0.0.2/24) on one switch.
func lan(_ sim: Sim = Sim()) throws -> (sim: Sim, sw: Switch, a: Host, b: Host) {
    let sw = Switch(sim: sim, id: "SW1")
    let a = Host(sim: sim, id: "A")
    let b = Host(sim: sim, id: "B")
    _ = try Link(sim: sim, try a.iface("eth0"), try sw.iface("Gi0/1"))
    _ = try Link(sim: sim, try b.iface("eth0"), try sw.iface("Gi0/2"))
    try a.setIp("eth0", "10.0.0.1/24")
    try b.setIp("eth0", "10.0.0.2/24")
    return (sim, sw, a, b)
}

/// H1 (10.0.1.10/24) — R1 (10.0.1.1 | 10.0.2.1) — H2 (10.0.2.10/24).
func routedPair(_ sim: Sim = Sim()) throws -> (sim: Sim, h1: Host, h2: Host, r1: Router) {
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let r1 = Router(sim: sim, id: "R1", ports: 2)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try h2.iface("eth0"))
    try r1.setIp("Gi0/0", "10.0.1.1/24")
    try r1.setIp("Gi0/1", "10.0.2.1/24")
    try h1.setIp("eth0", "10.0.1.10/24")
    try h1.setGateway("10.0.1.1")
    try h2.setIp("eth0", "10.0.2.10/24")
    try h2.setGateway("10.0.2.1")
    return (sim, h1, h2, r1)
}

/// H1 10.0.1.10 — R1 (10.0.1.1 | 10.0.12.1/30) — R2 (10.0.12.2/30 | 10.0.2.1) — H2 10.0.2.10.
func twoRouters(_ sim: Sim = Sim(), lastLink: LinkOptions = LinkOptions()) throws
    -> (sim: Sim, h1: Host, h2: Host, r1: Router, r2: Router) {
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let r1 = Router(sim: sim, id: "R1", ports: 2)
    let r2 = Router(sim: sim, id: "R2", ports: 2)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try r2.iface("Gi0/0"))
    _ = try Link(sim: sim, try r2.iface("Gi0/1"), try h2.iface("eth0"), lastLink)
    try r1.setIp("Gi0/0", "10.0.1.1/24")
    try r1.setIp("Gi0/1", "10.0.12.1/30")
    try r2.setIp("Gi0/0", "10.0.12.2/30")
    try r2.setIp("Gi0/1", "10.0.2.1/24")
    try r1.routes.addStatic("10.0.2.0/24", "10.0.12.2")
    try r2.routes.addStatic("10.0.1.0/24", "10.0.12.1")
    try h1.setIp("eth0", "10.0.1.10/24")
    try h1.setGateway("10.0.1.1")
    try h2.setIp("eth0", "10.0.2.10/24")
    try h2.setGateway("10.0.2.1")
    return (sim, h1, h2, r1, r2)
}
