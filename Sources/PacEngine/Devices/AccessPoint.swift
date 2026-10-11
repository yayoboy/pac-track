/// An autonomous access point (spec M11 §2, §6): a bridge between the Ethernet port `Gi0` and the radio `Dot11Radio0` (an Aironet's
/// names), one SSID, no IP address, no spanning tree.
final class AccessPoint: Node {
    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("Gi0")
        let air = addInterface("Dot11Radio0")
        air.radio = ApRadio(iface: air)
    }

    var radio: ApRadio { interfaces[1].radio as! ApRadio }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        sim.noteL2(frame, at: id)
    }

    /// Switched off or removed: its stations are dropped at once (spec M11 §5).
    override func reset() {
        radio.dropAll()
    }
}
