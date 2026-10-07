let MAC_AGING_NS = 300 * S

/// Transparent learning bridge (802.1D without STP).
final class Switch: Node {
    private var table: [Mac: (iface: Interface, seen: Int)] = [:]

    init(sim: Sim, id: String, ports: Int = 8) {
        super.init(sim: sim, id: id)
        for i in 1...ports { addInterface("Gi0/\(i)") }
    }

    func lookup(_ mac: Mac) -> Interface? {
        guard let entry = table[mac] else { return nil }
        if sim.now - entry.seen > MAC_AGING_NS {
            table[mac] = nil
            return nil
        }
        return entry.iface
    }

    func macTable() -> [(mac: Mac, iface: String, ageNs: Int)] {
        table.keys.sorted().compactMap { mac in
            guard let iface = lookup(mac), let seen = table[mac]?.seen else { return nil }
            return (mac, iface.name, sim.now - seen)
        }
    }

    override func reset() {
        table = [:]
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        sim.noteL2(frame, at: id)
        if !isGroupMac(frame.src) { table[frame.src] = (inIf, sim.now) }
        if !isGroupMac(frame.dst), let out = lookup(frame.dst) {
            if out !== inIf { out.send(frame) }
            return
        }
        for i in interfaces where i !== inIf && i.link != nil { i.send(frame) }
    }
}
