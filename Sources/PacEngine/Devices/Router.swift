class Router: IpNode {
    init(sim: Sim, id: String, ports: Int = 4) {
        super.init(sim: sim, id: id)
        forwarding = true
        defaultTtl = 255
        for i in 0..<ports { addInterface("Gi0/\(i)") }
    }

    /// IOS `interface Gi0/0.10` + `encapsulation dot1q 10` (spec M7 §3): the number after the dot is the VLAN. The subinterface
    /// shares the physical interface's MAC, sends through it tagged, and is listed after it by VLAN.
    func addSubinterface(_ name: String) throws {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let vlan = Int(parts[1]) else { throw EngineError("Invalid subinterface name: \"\(name)\"") }
        let parent = try iface(String(parts[0]))
        try checkVlan(vlan)
        let canonical = "\(parent.name).\(vlan)"
        guard !interfaces.contains(where: { $0.name == canonical }) else { throw EngineError("\(canonical) already exists") }
        // The physical interface itself matches (VLAN 0), so the index always exists.
        let after = interfaces.lastIndex { ($0.dot1q?.parent ?? $0) === parent && ($0.dot1q?.vlan ?? 0) < vlan }!
        insertInterface(Interface(node: self, name: canonical, mac: parent.mac, dot1q: (parent, vlan)), at: after + 1)
    }

    /// IOS `no interface Gi0/0.10`. Refused while NAT or a firewall rule names it (IOS would drop those with it); frames still on
    /// their way for its VLAN are dropped on arrival, and what is still queued to leave it (ARP retries, a delayed DHCP offer) is
    /// dropped as it goes down.
    func removeSubinterface(_ name: String) throws {
        let sub = try iface(name)
        guard sub.dot1q != nil else { throw EngineError("\(name) is not a subinterface") }
        if let nat, nat.config.inside.contains(name) || nat.config.outside == name { throw EngineError("\(name) has a NAT role") }
        if firewall?.config.rules.contains(where: { $0.iface == name }) == true { throw EngineError("\(name) has firewall rules") }
        if rip?.config.interfaces.contains(name) == true { throw EngineError("\(name) takes part in RIP") }
        if ospf?.config.interfaces.contains(where: { $0.name == name }) == true { throw EngineError("\(name) takes part in OSPF") }
        sub.up = false
        removeInterface(sub)
    }

    /// RIP and OSPF start again with the router (spec M8 §3, §4).
    override func powerOn() {
        rip?.start()
        ospf?.start()
    }

    /// A line going down or up, or a new bandwidth, changes RIP's connected networks and OSPF's interfaces at once (spec M8 §3, §4).
    override func linkChanged(_ iface: Interface) {
        rip?.refresh()
        ospf?.refresh()
    }
}
