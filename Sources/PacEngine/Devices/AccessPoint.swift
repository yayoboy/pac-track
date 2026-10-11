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

    /// The bridge (spec M11 §6): the association table is the radio side's MAC table; untagged frames only; no spanning tree.
    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        sim.noteL2(frame, at: id)
        let (wire, air) = (interfaces[0], interfaces[1])
        let group = isGroupMac(frame.dst)
        if inIf === air {
            var wired = frame
            wired.air = nil
            // To the cable unless the destination is one of its stations; back on the air (From DS) if it is, or a group.
            if group || !radio.associated(frame.dst) { wire.send(wired) }
            if group || radio.associated(frame.dst) { air.send(wired) }
            return
        }
        guard frame.vlan == nil else { return sim.emit(.drop, node: id, iface: inIf.name, frame: frame, reason: .unknownVlan) }
        // An autonomous Aironet runs no spanning tree and relays no BPDU.
        if case .bpdu = frame.payload { return }
        if group || radio.associated(frame.dst) { air.send(frame) }
    }

    /// Switched off or removed: its stations are dropped at once (spec M11 §5).
    override func reset() {
        radio.dropAll()
    }
}
