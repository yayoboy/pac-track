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
        // A subinterface sends through its physical interface, tagged with its VLAN.
        if let dot1q {
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
    /// IP interfaces in this interface's broadcast domain: across cables, switches and hubs, whatever their power or link state; self excluded.
    func segmentPeers() -> [Interface] {
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
        var todo = [self]
        var peers: [Interface] = []
        while let i = todo.popLast() {
            guard let peer = i.link?.peer(i), seen.insert(ObjectIdentifier(peer)).inserted else { continue }
            if peer.node is IpNode {
                peers.append(peer)
            } else {
                for next in peer.node.interfaces where seen.insert(ObjectIdentifier(next)).inserted { todo.append(next) }
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
