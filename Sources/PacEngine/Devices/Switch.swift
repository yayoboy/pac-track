let MAC_AGING_NS = 300 * S

/// Transparent learning bridge (802.1D without STP).
final class Switch: Node {
    private var table: [Mac: (iface: Interface, seen: Int)] = [:]

    init(sim: Sim, id: String, ports: Int = 8) {
        super.init(sim: sim, id: id)
        for i in 1...ports { addInterface("Gi0/\(i)") }
    }

    /// 8, 24 or 48 ports (spec §5.5); the ports taken away must be free.
    func setPorts(_ count: Int) throws {
        guard SWITCH_PORTS.contains(count) else { throw EngineError("A switch has 8, 24 or 48 ports") }
        if let busy = interfaces.dropFirst(count).first(where: { $0.link != nil }) { throw EngineError("\(busy.name) is connected") }
        while interfaces.count > count { removeLastInterface() }
        while interfaces.count < count { addInterface("Gi0/\(interfaces.count + 1)") }
        table = table.filter { entry in interfaces.contains { $0 === entry.value.iface } }
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
