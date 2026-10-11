/// A home Wi-Fi router (spec M11 §8): a router whose `Internet` port faces the provider, and a LAN of four ports (`LAN1`–`LAN4`) and
/// an access point's radio (`WLAN`) bridged together behind `LAN`, the interface that holds its address. The bridge learns MAC
/// addresses like a switch's, without VLANs or spanning tree; the radio side is the association table, as on an access point.
final class HomeRouter: Router {
    private var table: [Mac: (iface: Interface, seen: Int)] = [:]
    /// Its name server for the LAN, always on (spec M11 §8).
    private var dns: DnsForwarder?

    init(sim: Sim, id: String) {
        super.init(sim: sim, id: id, ports: 0)
        defaultTtl = 64 // the Linux inside
        addInterface("Internet")
        for i in 1...4 { addInterface("LAN\(i)") }
        let air = addInterface("WLAN")
        air.radio = ApRadio(iface: air)
        addInterface("LAN").bridge = true
        dns = try? DnsForwarder(node: self) // UDP 53 is free on a new node
    }

    var wan: Interface { interfaces[0] }
    var radio: ApRadio { interfaces[5].radio as! ApRadio }
    var lan: Interface { interfaces[6] }
    /// The bridge's ports: the four LAN ports, then the radio.
    var ports: ArraySlice<Interface> { interfaces[1...5] }

    /// Addresses go on `Internet` and `LAN` only.
    func checkAddressable(_ name: String) throws {
        if ports.contains(where: { $0.name == name }) { throw EngineError("\(name) is a port of the LAN bridge") }
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        guard inIf !== wan else { return super.receive(frame, on: inIf) }
        sim.noteL2(frame, at: id)
        guard frame.vlan == nil else { return sim.emit(.drop, node: id, iface: inIf.name, frame: frame, reason: .unknownVlan) }
        // A home router's switch runs no spanning tree and relays no BPDU.
        if case .bpdu = frame.payload { return }
        var f = frame
        f.air = nil
        if inIf.radio == nil, !isGroupMac(f.src) { table[f.src] = (inIf, sim.now) }
        if f.dst == lan.mac || isGroupMac(f.dst) { super.receive(f, on: lan) }
        if f.dst != lan.mac { bridge(f, from: inIf) }
    }

    /// Out of the bridge (spec M11 §8): to an authorized station or a group on the air (back on the air, From DS, when it came from
    /// there); to the port that learned the destination, else to every cabled LAN port; never back out of the port it came in by.
    /// `inIf` is nil for the router's own frames.
    func bridge(_ f: EthernetFrame, from inIf: Interface?) {
        let group = isGroupMac(f.dst)
        let station = !group && radio.associated(f.dst)
        if group || station { radio.iface.send(f) }
        if station { return }
        let out = group ? nil : lookup(f.dst)
        for p in ports.dropLast() where p !== inIf && p.lineUp && (out == nil || p === out) { p.send(f) }
    }

    private func lookup(_ mac: Mac) -> Interface? {
        guard let entry = table[mac], sim.now - entry.seen <= MAC_AGING_NS else { return nil }
        return entry.iface
    }

    /// Switched off or removed: the bridge forgets what it learned and the stations are dropped at once (spec M11 §5).
    override func reset() {
        super.reset()
        table = [:]
        radio.dropAll()
    }
}
