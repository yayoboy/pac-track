/// VDSL2 profile 17a, the common "up to 100 Mb/s" FTTC line (spec M12 §2), in b/s.
public let VDSL2_SYNC = (down: 100e6, up: 20e6)

/// DSL modem in bridge mode (spec M12 §2): the line `dsl0`, at its sync rates, and `eth0` toward the home router. Every frame goes
/// out of the other port as it came (VLAN tags, BPDUs and broadcasts too), like a two-port repeater; no address, no services.
final class Modem: Node {
    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("dsl0").sync = VDSL2_SYNC
        addInterface("eth0")
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        sim.noteL2(frame, at: id)
        for i in interfaces where i !== inIf && i.link != nil { i.send(frame) }
    }
}
