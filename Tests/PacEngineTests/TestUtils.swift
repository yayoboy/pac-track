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
