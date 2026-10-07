/// Layer-1 repeater. Collisions are not modelled (links are full duplex).
final class Hub: Node {
    init(sim: Sim, id: String, ports: Int = 8) {
        super.init(sim: sim, id: id)
        for i in 1...ports { addInterface("p\(i)") }
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        for i in interfaces where i !== inIf && i.link != nil { i.send(frame) }
    }
}
