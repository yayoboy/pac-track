final class Interface {
    unowned let node: Node
    let name: String
    let mac: Mac
    /// The cable plugged in here. The interface owns it; the link refers back `unowned`.
    var link: Link?
    var up = true
    var mtu = 1500
    var ipv4: Cidr?
    /// Switch ports only: access or trunk and the VLANs (IOS `switchport`).
    var switchport = Switchport()
    /// Router subinterfaces only (IOS `encapsulation dot1q`): the physical interface it rides on and its VLAN.
    let dot1q: (parent: Interface, vlan: Int)?

    init(node: Node, name: String, mac: Mac, dot1q: (parent: Interface, vlan: Int)? = nil) {
        self.node = node
        self.name = name
        self.mac = mac
        self.dot1q = dot1q
    }

    var id: String { "\(node.id)/\(name)" }

    func send(_ frame: EthernetFrame) {
        // A subinterface sends through its physical interface, tagged with its VLAN; once deleted (down) it sends nothing.
        if let dot1q {
            guard up else { return node.sim.emit(.drop, node: node.id, iface: name, frame: frame, reason: .ifaceDown) }
            var tagged = frame
            tagged.vlan = dot1q.vlan
            return dot1q.parent.send(tagged)
        }
        let reason: DropReason? = !node.powered || !up ? .ifaceDown : link == nil ? .noLink : nil
        if let reason {
            node.sim.emit(.drop, node: node.id, iface: name, frame: frame, reason: reason)
            return
        }
        link!.transmit(from: self, frame)
    }
}

extension Interface {
    /// IP interfaces in this interface's broadcast domain: across cables, hubs and switches within one VLAN (access ports, a trunk's
    /// allowed and native VLANs, subinterfaces), whatever their power or link state; self excluded.
    func segmentPeers() -> [Interface] {
        /// An interface reached by a frame carrying `tag` on the wire.
        struct Hop: Hashable {
            let iface: ObjectIdentifier
            let tag: Int?
        }
        // A subinterface's frames leave its physical interface tagged.
        let start = (iface: dot1q?.parent ?? self, tag: dot1q?.vlan)
        var seen: Set<Hop> = [Hop(iface: ObjectIdentifier(start.iface), tag: start.tag)]
        var todo = [start]
        var peers: [Interface] = []
        while let hop = todo.popLast() {
            guard let peer = hop.iface.link?.peer(hop.iface), seen.insert(Hop(iface: ObjectIdentifier(peer), tag: hop.tag)).inserted else { continue }
            if peer.node is IpNode {
                // Untagged: the physical interface; tagged: its subinterface for that VLAN, if any.
                let ip = peer.node.interfaces.first { hop.tag == nil ? $0 === peer : $0.dot1q?.parent === peer && $0.dot1q?.vlan == hop.tag }
                if let ip { peers.append(ip) }
            } else if peer.node is Switch {
                guard let vlan = peer.switchport.ingress(hop.tag) else { continue }
                for next in peer.node.interfaces where next !== peer && next.switchport.carries(vlan) {
                    todo.append((next, next.switchport.tag(vlan)))
                }
            } else {
                for next in peer.node.interfaces where next !== peer { todo.append((next, hop.tag)) }
            }
        }
        return peers
    }
}

/// Base class of every device. Subclasses override `receive`.
class Node {
    unowned let sim: Sim
    let id: String
    var name: String
    private(set) var interfaces: [Interface] = []
    /// Interfaces taken away (a smaller switch): kept alive while a frame that was on their cable finishes (links refer to them `unowned`).
    // ponytail: never freed before the Sim is replaced; at most 40 per resize
    private var retired: [Interface] = []
    var powered = true

    init(sim: Sim, id: String) {
        self.sim = sim
        self.id = id
        name = id
        sim.adopt(self)
    }

    @discardableResult
    func addInterface(_ name: String) -> Interface {
        let iface = Interface(node: self, name: name, mac: sim.newMac())
        interfaces.append(iface)
        return iface
    }

    func removeLastInterface() {
        retired.append(interfaces.removeLast())
    }

    /// A router subinterface, at the place `show ip interface brief` lists it.
    func insertInterface(_ iface: Interface, at index: Int) {
        interfaces.insert(iface, at: index)
    }

    /// A deleted router subinterface: retired like the ports a smaller switch gives up.
    func removeInterface(_ iface: Interface) {
        interfaces.removeAll { $0 === iface }
        retired.append(iface)
    }

    func iface(_ name: String) throws -> Interface {
        guard let iface = interfaces.first(where: { $0.name == name }) else { throw EngineError("\(id) has no interface \(name)") }
        return iface
    }

    func receive(_ frame: EthernetFrame, on iface: Interface) {
        fatalError("\(type(of: self)) must override receive(_:on:)")
    }

    /// Power cycle: forgets everything learned at run time (configuration stays).
    func reset() {}

    /// Power on: starts what boots with the device (a DHCP client); configuration was kept.
    func powerOn() {}
}
