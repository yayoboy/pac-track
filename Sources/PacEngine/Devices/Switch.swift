let MAC_AGING_NS = 300 * S

/// A MAC table key: one address can sit in several VLANs (a router-on-a-stick's MAC is in all of them).
private struct MacKey: Hashable {
    let vlan: Int
    let mac: Mac
}

/// Transparent learning bridge with 802.1Q VLANs (802.1D without STP): one MAC table per VLAN, flooding confined to the frame's VLAN.
final class Switch: Node {
    private var table: [MacKey: (iface: Interface, seen: Int)] = [:]

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

    /// IOS `switchport mode access|trunk` with its VLANs; the addresses the port learned are flushed, as IOS does on a VLAN change.
    func setSwitchport(_ name: String, _ c: PortConfig) throws {
        let port = try iface(name)
        port.switchport = try Switchport(c)
        table = table.filter { $0.value.iface !== port }
    }

    func lookup(_ mac: Mac, vlan: Int) -> Interface? {
        let key = MacKey(vlan: vlan, mac: mac)
        guard let entry = table[key] else { return nil }
        if sim.now - entry.seen > MAC_AGING_NS {
            table[key] = nil
            return nil
        }
        return entry.iface
    }

    /// By VLAN, then MAC.
    func macTable() -> [(vlan: Int, mac: Mac, iface: String, ageNs: Int)] {
        table.keys.sorted { ($0.vlan, $0.mac) < ($1.vlan, $1.mac) }.compactMap { key in
            guard let iface = lookup(key.mac, vlan: key.vlan), let seen = table[key]?.seen else { return nil }
            return (key.vlan, key.mac, iface.name, sim.now - seen)
        }
    }

    override func reset() {
        table = [:]
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        sim.noteL2(frame, at: id)
        guard let vlan = inIf.switchport.ingress(frame.vlan) else {
            sim.emit(.drop, node: id, iface: inIf.name, frame: frame, reason: .vlanNotAllowed)
            return
        }
        if !isGroupMac(frame.src) { table[MacKey(vlan: vlan, mac: frame.src)] = (inIf, sim.now) }
        if !isGroupMac(frame.dst), let out = lookup(frame.dst, vlan: vlan) {
            if out !== inIf { forward(frame, vlan, to: out) }
            return
        }
        for i in interfaces where i !== inIf && i.link != nil && i.switchport.carries(vlan) { forward(frame, vlan, to: i) }
    }

    /// Out of `port` in `vlan`: tagged on a trunk unless `vlan` is its native one.
    private func forward(_ frame: EthernetFrame, _ vlan: Int, to port: Interface) {
        var out = frame
        out.vlan = port.switchport.tag(vlan)
        port.send(out)
    }
}
