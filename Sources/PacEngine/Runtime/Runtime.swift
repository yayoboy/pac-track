import Foundation

private let MAX_APPS = 20
/// Longest wall-clock gap simulated in one call; longer gaps (sleep, hidden window) are dropped.
private let MAX_STEP_MS = 100.0
/// Simulation mode, play: one step per half second of wall time at 1×.
private let SIM_STEP_MS = 500.0
/// ponytail: fixed work budget per clock tick; a storm slows simulated time instead of freezing the app (spec §6 effective speed, not yet reported)
private let MAX_EVENTS_PER_ADVANCE = 50_000
/// A step whose events log nothing (only timers) gives up after this many.
private let MAX_SILENT_EVENTS = 100_000

/// Whole seconds left, rounded up (a lease with 0.2 s left shows 1 s).
private func secondsLeft(_ ns: Int) -> Int {
    (ns + S - 1) / S
}

private enum Program {
    case ping(Ping)
    case trace(Traceroute)
    case nslookup(NsLookup)

    var lines: [String] {
        switch self {
        case .ping(let p): p.result.lines
        case .trace(let t): t.result.lines
        case .nslookup(let n): n.result.lines
        }
    }

    var done: Bool {
        switch self {
        case .ping(let p): p.result.done
        case .trace(let t): t.result.done
        case .nslookup(let n): n.result.done
        }
    }

    func stop() {
        switch self {
        case .ping(let p): p.stop()
        case .trace(let t): t.stop()
        case .nslookup(let n): n.stop()
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
    public private(set) var mode = SimMode.realtime
    /// Bumped by `load`: a new Sim restarts event sequence numbers.
    public private(set) var epoch = 0
    private var stepCredit = 0.0
    /// Clock state to restore when leaving Simulation mode.
    private var runningBeforeSimulation = true
    private var last: Snapshot?

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
            // Nothing keeps running on a removed device (its DHCP client would broadcast forever).
            node.powered = false
            node.reset()
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
            try link(id).disconnect()
            links[id] = nil
            linkOrder.removeAll { $0 == id }
        case let .setIp(node, iface, cidr):
            let ip = try ipNode(node)
            if let client = (ip as? Host)?.dhcp, client.iface.name == iface { throw EngineError("\(iface) is configured by DHCP") }
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
            start(node, "ping \(t)", .ping(try Ping(node: try liveIpNode(node), target: t)))
        case let .traceroute(node, target):
            let t = target.trimmingCharacters(in: .whitespaces)
            start(node, "traceroute \(t)", .trace(try Traceroute(node: try liveIpNode(node), target: t)))
        case let .setIfaceMode(node, iface, mode):
            let n = try get(node)
            guard let host = n as? Host else { throw EngineError("\(n.name) has no DHCP client") }
            _ = try host.iface(iface)
            try host.setDhcp(mode == .dhcp)
        case let .setNameServer(node, ip):
            let n = try ipNode(node)
            let text = ip?.trimmingCharacters(in: .whitespaces) ?? ""
            n.nameServer = try text.isEmpty ? nil : parseIp(text)
        case let .setDhcpServer(node, config):
            try setDhcpServer(node, config, requireInSubnet: true)
        case let .setDnsServer(node, records):
            let n = try ipNode(node)
            guard records == nil || nodes[node]?.kind == .server else { throw EngineError("\(n.name) cannot run a DNS server") }
            try n.configureDnsServer(records)
        case let .renewDhcp(node):
            let n = try liveIpNode(node)
            guard let client = (n as? Host)?.dhcp else { throw EngineError("\(n.name) is not using DHCP") }
            client.renewNow()
        case let .nslookup(node, name):
            let t = name.trimmingCharacters(in: .whitespaces)
            start(node, "nslookup \(t)", .nslookup(try NsLookup(node: try liveIpNode(node), name: t)))
        case let .setMode(value):
            guard value != mode else { return }
            if value == .simulation { runningBeforeSimulation = running }
            mode = value
            running = value == .realtime && runningBeforeSimulation
            stepCredit = 0
        case .step:
            step()
        case let .setPower(id, on):
            let node = try get(id)
            guard node.powered != on else { return }
            node.powered = on
            if on {
                node.powerOn()
            } else {
                node.reset()
                for app in apps where app.node == id { app.program.stop() }
            }
        case let .updateLink(id, options):
            try link(id).update(options)
        case let .setLinkUp(id, up):
            try link(id).up = up
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
        switch mode {
        case .realtime:
            sim.sched.runUntil(sim.now + Int((min(wallMs, MAX_STEP_MS) * Double(MS) * speed).rounded()), maxEvents: MAX_EVENTS_PER_ADVANCE)
        case .simulation:
            stepCredit += min(wallMs, MAX_STEP_MS) * speed
            while stepCredit >= SIM_STEP_MS {
                stepCredit -= SIM_STEP_MS
                step()
            }
        }
    }

    /// Runs scheduled events until one is logged (a frame sent, received or dropped) or none are left.
    private func step() {
        let before = sim.log.total
        var budget = MAX_SILENT_EVENTS
        while sim.log.total == before, budget > 0, sim.sched.step() { budget -= 1 }
    }

    /// Log entries from `seq` on, at most the newest `limit` (the UI pulls only what it has not seen).
    public func events(from seq: Int, limit: Int = 5000) -> [EventView] {
        sim.log.since(max(seq, sim.log.total - limit)).map(eventView)
    }

    /// Header-by-header view of one logged frame; nil once the ring buffer dropped it.
    public func pdu(_ seq: Int) -> [PduLayer]? {
        sim.log.event(seq).map(pduLayers)
    }

    /// The version moves only when something visible changed, so a paused window does not redraw.
    public func snapshot() -> Snapshot {
        var s = build()
        s.version = last?.version ?? 0
        if s == last { return s }
        s.version += 1
        last = s
        return s
    }

    private func build() -> Snapshot {
        let now = sim.now
        let nodeViews = nodeOrder.map { id -> NodeView in
            let (node, kind) = nodes[id]!
            let ip = node as? IpNode
            let host = node as? Host
            return NodeView(
                id: id,
                kind: kind,
                name: node.name,
                powered: node.powered,
                ifaces: node.interfaces.map {
                    IfaceView(name: $0.name, mac: $0.mac, cidr: $0.ipv4.map { "\(formatIp($0.addr))/\($0.prefix)" }, linked: $0.link != nil,
                              mode: host?.dhcp?.iface === $0 ? .dhcp : .`static`)
                },
                routes: ip?.routes.view().map {
                    RouteRow(dest: "\(formatIp($0.network))/\($0.prefix)", nextHop: $0.nextHop.map(formatIp), iface: $0.iface,
                             isStatic: $0.isStatic, dhcp: $0.dhcp)
                } ?? [],
                arp: ip?.arp.entries().map {
                    ArpRow(ip: formatIp($0.ip), mac: $0.mac, iface: $0.iface, ttlS: ($0.expiresAt - now + S - 1) / S)
                } ?? [],
                mac: (node as? Switch)?.macTable().map { MacRow(mac: $0.mac, iface: $0.iface, ageS: $0.ageNs / S) } ?? [],
                nameServer: ip?.nameServer.map(formatIp),
                learnedNameServer: ip?.learnedNameServer.map(formatIp),
                dhcpClient: host?.dhcp.map { c in
                    DhcpClientView(state: c.state.rawValue, server: c.server.map(formatIp),
                                   leaseS: c.hasLease ? secondsLeft(c.expiry - now) : nil,
                                   renewS: c.state == .bound ? secondsLeft(c.t1 - now) : nil)
                },
                dhcpServer: ip?.dhcpServer?.pool.config,
                leases: ip?.dhcpServer?.view().map {
                    LeaseRow(ip: formatIp($0.ip), mac: $0.mac, expiresS: secondsLeft($0.expiresAt - now), bound: $0.bound)
                } ?? [],
                dnsRecords: ip?.dnsServer?.records.map { DnsRecord(name: $0.name, ip: formatIp($0.addr), ttl: $0.ttl) },
                dnsCache: ip?.resolver.entries().flatMap { e in
                    e.addrs.map { DnsCacheRow(name: e.name, ip: formatIp($0), ttlS: secondsLeft(e.expiresAt - now)) }
                } ?? []
            )
        }
        let linkViews = linkOrder.map { id in
            let l = links[id]!
            return LinkView(id: id, a: IfaceRef(node: l.a.node.id, iface: l.a.name), b: IfaceRef(node: l.b.node.id, iface: l.b.name),
                            options: l.opts, up: l.up)
        }
        let appViews = apps.map { AppView(id: $0.id, node: $0.node, title: $0.title, lines: $0.program.lines, done: $0.program.done) }
        return Snapshot(version: 0, seed: seed, timeNs: now, running: running, speed: speed, mode: mode, epoch: epoch,
                        eventCount: sim.log.total, nodes: nodeViews, links: linkViews, apps: appViews,
                        warnings: sim.warnings.map { WarningView(id: $0.id, node: $0.node, timeNs: $0.time) })
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

    private func link(_ id: String) throws -> Link {
        guard let link = links[id] else { throw EngineError("Unknown link \(id)") }
        return link
    }

    private func liveIpNode(_ id: String) throws -> IpNode {
        let ip = try ipNode(id)
        guard ip.powered else { throw EngineError("\(ip.name) is powered off") }
        return ip
    }

    private func setDhcpServer(_ id: String, _ config: DhcpConfig?, requireInSubnet: Bool) throws {
        let ip = try ipNode(id)
        guard config == nil || nodes[id]?.kind == .router || nodes[id]?.kind == .server else {
            throw EngineError("\(ip.name) cannot run a DHCP server")
        }
        try ip.configureDhcpServer(config, requireInSubnet: requireInSubnet)
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
        for l in t.links {
            try next.handle(.connect(id: l.id, a: l.a, b: l.b))
            try next.handle(.updateLink(id: l.id, options: l.options))
            if !l.up { try next.handle(.setLinkUp(id: l.id, up: false)) }
        }
        for n in t.nodes {
            for r in n.routes { try next.ipNode(n.id).routes.addStatic(r.cidr, r.nextHop, requireReachable: false) }
        }
        for n in t.nodes {
            for i in n.ifaces where i.mode == .dhcp { try next.handle(.setIfaceMode(node: n.id, iface: i.name, mode: .dhcp)) }
            if let server = n.nameServer { try next.handle(.setNameServer(node: n.id, ip: server)) }
            if let config = n.dhcp { try next.setDhcpServer(n.id, config, requireInSubnet: false) }
            if let records = n.dns { try next.handle(.setDnsServer(node: n.id, records: records)) }
        }
        for n in t.nodes where !n.powered { try next.handle(.setPower(id: n.id, on: false)) }
        for app in apps { app.program.stop() }
        sim = next.sim
        seed = next.seed
        nodes = next.nodes
        nodeOrder = next.nodeOrder
        links = next.links
        linkOrder = next.linkOrder
        apps = []
        epoch += 1
        stepCredit = 0
    }
}