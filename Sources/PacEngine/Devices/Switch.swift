let MAC_AGING_NS = 300 * S

/// A MAC table key: one address can sit in several VLANs (a router-on-a-stick's MAC is in all of them).
private struct MacKey: Hashable {
    let vlan: Int
    let mac: Mac
}

/// Transparent learning bridge with 802.1Q VLANs and PVST+: one MAC table and one 802.1D spanning tree per VLAN, frames moving
/// only between ports forwarding in the frame's VLAN.
final class Switch: Node {
    private var table: [MacKey: (iface: Interface, seen: Int)] = [:]
    /// PVST+ instances by VLAN: one for each VLAN of the network that an up port of this switch carries.
    private(set) var stp: [Int: Stp] = [:]

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
        sim.syncStp()
    }

    /// IOS `switchport mode access|trunk` with its VLANs; the addresses the port learned are flushed, as IOS does on a VLAN change.
    func setSwitchport(_ name: String, _ c: PortConfig) throws {
        let port = try iface(name)
        port.switchport = try Switchport(c)
        table = table.filter { $0.value.iface !== port }
        sim.syncStp()
    }

    func lookup(_ mac: Mac, vlan: Int) -> Interface? {
        let key = MacKey(vlan: vlan, mac: mac)
        guard let entry = table[key] else { return nil }
        // During a topology change the VLAN's entries age out after forward delay (spec M7 §4).
        let aging = stp[vlan]?.topologyChange == true ? STP_FORWARD_DELAY_NS : MAC_AGING_NS
        if sim.now - entry.seen > aging {
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

    /// What `port` learned in `vlan`: forgotten when it stops forwarding or learning there.
    func flush(_ port: Interface, _ vlan: Int) {
        table = table.filter { !($0.key.vlan == vlan && $0.value.iface === port) }
    }

    /// Starts, updates or stops the PVST+ instances after a change of cables, power, port VLANs or VLANs in the network.
    func syncStp() {
        guard powered else { return }
        let vlans = sim.vlans()
        for vlan in vlans.union(stp.keys).sorted() {
            let members = vlans.contains(vlan) ? interfaces.filter { $0.switchport.carries(vlan) && isUp($0) } : []
            if let instance = stp[vlan] {
                instance.sync(members)
                if instance.isEmpty { stp[vlan] = nil }
            } else if !members.isEmpty {
                stp[vlan] = Stp(sw: self, vlan: vlan, members: members)
            }
        }
    }

    /// Up while the cable is plugged and working and the device at its other end is on.
    private func isUp(_ port: Interface) -> Bool {
        guard powered, let link = port.link, link.up else { return false }
        return link.peer(port).node.powered
    }

    override func linkChanged(_ iface: Interface) {
        syncStp()
    }

    override func powerOn() {
        syncStp()
    }

    override func reset() {
        table = [:]
        stp = [:]
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        sim.noteL2(frame, at: id)
        guard let vlan = inIf.switchport.ingress(frame.vlan) else {
            sim.emit(.drop, node: id, iface: inIf.name, frame: frame, reason: .vlanNotAllowed)
            return
        }
        // A BPDU is for this switch's tree of its VLAN; it is never forwarded.
        if case .bpdu(let b) = frame.payload {
            stp[vlan]?.receive(b, on: inIf)
            return
        }
        // No instance: the VLAN exists nowhere in the network.
        guard let instance = stp[vlan], let state = instance.state(inIf) else {
            sim.emit(.drop, node: id, iface: inIf.name, frame: frame, reason: .vlanNotAllowed)
            return
        }
        if state == .learning || state == .forwarding, !isGroupMac(frame.src) { table[MacKey(vlan: vlan, mac: frame.src)] = (inIf, sim.now) }
        guard state == .forwarding else {
            sim.emit(.drop, node: id, iface: inIf.name, frame: frame, reason: .stpDiscarding)
            return
        }
        if !isGroupMac(frame.dst), let out = lookup(frame.dst, vlan: vlan) {
            if out !== inIf && instance.state(out) == .forwarding { forward(frame, vlan, to: out) }
            return
        }
        for i in interfaces where i !== inIf && instance.state(i) == .forwarding { forward(frame, vlan, to: i) }
    }

    /// Out of `port` in `vlan`: tagged on a trunk unless `vlan` is its native one.
    private func forward(_ frame: EthernetFrame, _ vlan: Int, to port: Interface) {
        var out = frame
        out.vlan = port.switchport.tag(vlan)
        port.send(out)
    }
}
