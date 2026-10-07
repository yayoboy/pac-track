import Foundation

private let MAX_APPS = 20
/// Longest wall-clock gap simulated in one call; longer gaps (sleep, hidden window) are dropped.
private let MAX_STEP_MS = 100.0

private enum Program {
    case ping(Ping)
    case trace(Traceroute)

    var lines: [String] {
        switch self {
        case .ping(let p): p.result.lines
        case .trace(let t): t.result.lines
        }
    }

    var done: Bool {
        switch self {
        case .ping(let p): p.result.done
        case .trace(let t): t.result.done
        }
    }

    func stop() {
        switch self {
        case .ping(let p): p.stop()
        case .trace(let t): t.stop()
        }
    }
}

private struct App {
    let id: Int
    let node: String
    let title: String
    let program: Program
}

/// Owns one simulation and translates protocol commands into engine calls. Not thread-safe: confine it (PacKit's `Simulation` actor).
public final class Runtime {
    public private(set) var running = true
    public private(set) var speed = 1.0
    private var sim: Sim
    private var seed: UInt32
    private var nodes: [String: (node: Node, kind: DeviceKind)] = [:]
    private var nodeOrder: [String] = []
    private var links: [String: Link] = [:]
    private var linkOrder: [String] = []
    private var apps: [App] = []
    private var appId = 0
    private var version = 0

    public init(seed: UInt32 = 1) {
        self.seed = seed
        sim = Sim(seed: seed)
    }

    public func handle(_ cmd: Command) throws {
        switch cmd {
        case let .addNode(id, kind, name):
            guard nodes[id] == nil else { throw EngineError("Node \(id) already exists") }
            let node = create(id, kind)
            node.name = name
            nodes[id] = (node, kind)
            nodeOrder.append(id)
        case let .removeNode(id):
            let node = try get(id)
            for linkId in linkOrder where links[linkId]!.a.node === node || links[linkId]!.b.node === node {
                links[linkId]!.disconnect()
                links[linkId] = nil
            }
            linkOrder.removeAll { links[$0] == nil }
            for app in apps where app.node == id { app.program.stop() }
            nodes[id] = nil
            nodeOrder.removeAll { $0 == id }
        case let .rename(id, name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw EngineError("Name cannot be empty") }
            try get(id).name = trimmed
        case let .connect(id, a, b):
            guard links[id] == nil else { throw EngineError("Link \(id) already exists") }
            links[id] = try Link(sim: sim, try get(a.node).iface(a.iface), try get(b.node).iface(b.iface))
            linkOrder.append(id)
        case let .disconnect(id):
            guard let link = links[id] else { throw EngineError("Unknown link \(id)") }
            link.disconnect()
            links[id] = nil
            linkOrder.removeAll { $0 == id }
        case let .setIp(node, iface, cidr):
            let ip = try ipNode(node)
            if let cidr = cidr?.trimmingCharacters(in: .whitespaces), !cidr.isEmpty {
                try ip.setIp(iface, cidr)
            } else {
                try ip.iface(iface).ipv4 = nil
            }
        case let .addRoute(node, cidr, nextHop):
            try ipNode(node).routes.addStatic(cidr.trimmingCharacters(in: .whitespaces), nextHop.trimmingCharacters(in: .whitespaces))
        case let .removeRoute(node, cidr):
            try ipNode(node).routes.removeStatic(cidr)
        case let .ping(node, target):
            let t = target.trimmingCharacters(in: .whitespaces)
            start(node, "ping \(t)", .ping(try Ping(node: try ipNode(node), target: t)))
        case let .traceroute(node, target):
            let t = target.trimmingCharacters(in: .whitespaces)
            start(node, "traceroute \(t)", .trace(try Traceroute(node: try ipNode(node), target: t)))
        case let .setRunning(value):
            running = value
        case let .setSpeed(value):
            guard value > 0 && value <= 1000 else { throw EngineError("Invalid speed: \(value)") }
            speed = value
        case let .load(topology):
            try load(topology)
        }
    }

    public func advance(wallMs: Double) {
        guard running else { return }
        sim.run(Int((min(wallMs, MAX_STEP_MS) * Double(MS) * speed).rounded()))
    }

    public func snapshot() -> Snapshot {
        version += 1
        let now = sim.now
        let nodeViews = nodeOrder.map { id -> NodeView in
            let (node, kind) = nodes[id]!
            let ip = node as? IpNode
            return NodeView(
                id: id,
                kind: kind,
                name: node.name,
                ifaces: node.interfaces.map {
                    IfaceView(name: $0.name, mac: $0.mac, cidr: $0.ipv4.map { "\(formatIp($0.addr))/\($0.prefix)" }, linked: $0.link != nil)
                },
                routes: ip?.routes.view().map {
                    RouteRow(dest: "\(formatIp($0.network))/\($0.prefix)", nextHop: $0.nextHop.map(formatIp), iface: $0.iface, isStatic: $0.isStatic)
                } ?? [],
                arp: ip?.arp.entries().map {
                    ArpRow(ip: formatIp($0.ip), mac: $0.mac, iface: $0.iface, ttlS: ($0.expiresAt - now + S - 1) / S)
                } ?? [],
                mac: (node as? Switch)?.macTable().map { MacRow(mac: $0.mac, iface: $0.iface, ageS: $0.ageNs / S) } ?? []
            )
        }
        let linkViews = linkOrder.map { id in
            let l = links[id]!
            return LinkView(id: id, a: IfaceRef(node: l.a.node.id, iface: l.a.name), b: IfaceRef(node: l.b.node.id, iface: l.b.name))
        }
        let appViews = apps.map { AppView(id: $0.id, node: $0.node, title: $0.title, lines: $0.program.lines, done: $0.program.done) }
        return Snapshot(version: version, seed: seed, timeNs: now, running: running, speed: speed, nodes: nodeViews, links: linkViews, apps: appViews)
    }

    private func create(_ id: String, _ kind: DeviceKind) -> Node {
        switch kind {
        case .pc, .laptop, .server: Host(sim: sim, id: id)
        case .router: Router(sim: sim, id: id)
        case .switch: Switch(sim: sim, id: id)
        case .hub: Hub(sim: sim, id: id)
        }
    }

    private func get(_ id: String) throws -> Node {
        guard let entry = nodes[id] else { throw EngineError("Unknown node \(id)") }
        return entry.node
    }

    private func ipNode(_ id: String) throws -> IpNode {
        let node = try get(id)
        guard let ip = node as? IpNode else { throw EngineError("\(node.name) has no IP stack") }
        return ip
    }

    private func start(_ node: String, _ title: String, _ program: Program) {
        appId += 1
        apps.append(App(id: appId, node: node, title: title, program: program))
        if apps.count > MAX_APPS { apps.removeFirst().program.stop() }
    }

    /// Builds the new network aside and swaps it in only if every step succeeds.
    private func load(_ t: Topology) throws {
        guard t.version == 1 else { throw EngineError("Unsupported or corrupt project file") }
        let next = Runtime(seed: t.seed)
        for n in t.nodes {
            try next.handle(.addNode(id: n.id, kind: n.kind, name: n.name))
            for i in n.ifaces where i.cidr != nil { try next.handle(.setIp(node: n.id, iface: i.name, cidr: i.cidr)) }
        }
        for l in t.links { try next.handle(.connect(id: l.id, a: l.a, b: l.b)) }
        for n in t.nodes {
            for r in n.routes { try next.handle(.addRoute(node: n.id, cidr: r.cidr, nextHop: r.nextHop)) }
        }
        for app in apps { app.program.stop() }
        sim = next.sim
        seed = next.seed
        nodes = next.nodes
        nodeOrder = next.nodeOrder
        links = next.links
        linkOrder = next.linkOrder
        apps = []
    }
}