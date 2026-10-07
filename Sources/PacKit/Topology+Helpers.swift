import Foundation
import PacEngine

extension DeviceKind {
    public var label: String {
        switch self {
        case .pc: "PC"
        case .laptop: "Laptop"
        case .server: "Server"
        case .router: "Router"
        case .switch: "Switch"
        case .hub: "Hub"
        }
    }

    var namePrefix: String {
        switch self {
        case .pc: "PC"
        case .laptop: "LAPTOP"
        case .server: "SRV"
        case .router: "R"
        case .switch: "SW"
        case .hub: "HUB"
        }
    }

    public var hasIp: Bool { self != .switch && self != .hub }
}

public func defaultName(_ kind: DeviceKind, existing nodes: [NodeView]) -> String {
    let taken = Set(nodes.map(\.name))
    var i = 1
    while taken.contains("\(kind.namePrefix)\(i)") { i += 1 }
    return "\(kind.namePrefix)\(i)"
}

public func firstFreeIface(_ node: NodeView) -> String? {
    node.ifaces.first { !$0.linked }?.name
}

public func firstIp(_ node: NodeView) -> String? {
    node.ifaces.lazy.compactMap(\.cidr).first.map { String($0.split(separator: "/")[0]) }
}

public func gatewayOf(_ node: NodeView) -> String? {
    node.routes.first { $0.isStatic && $0.dest == "0.0.0.0/0" }?.nextHop
}

public func makeTopology(_ s: Snapshot, _ positions: [String: Pos]) -> Topology {
    Topology(seed: s.seed, nodes: s.nodes.map { n in
        TopologyNode(id: n.id, kind: n.kind, name: n.name, pos: positions[n.id] ?? Pos(x: 0, y: 0),
                     ifaces: n.ifaces.map { TopologyIface(name: $0.name, cidr: $0.cidr) },
                     routes: n.routes.filter(\.isStatic).map { TopologyRoute(cidr: $0.dest, nextHop: $0.nextHop ?? "") })
    }, links: s.links)
}

public func positions(of t: Topology) -> [String: Pos] {
    Dictionary(uniqueKeysWithValues: t.nodes.map { ($0.id, $0.pos) })
}

/// True when two topologies differ at most in node positions.
public func sameNetwork(_ a: Topology, _ b: Topology) -> Bool {
    func stripped(_ t: Topology) -> Topology {
        var copy = t
        for i in copy.nodes.indices { copy.nodes[i].pos = Pos(x: 0, y: 0) }
        return copy
    }
    return stripped(a) == stripped(b)
}

public func newId() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

public func snap(_ p: Pos, grid: Double = 14) -> Pos {
    Pos(x: (p.x / grid).rounded() * grid, y: (p.y / grid).rounded() * grid)
}
