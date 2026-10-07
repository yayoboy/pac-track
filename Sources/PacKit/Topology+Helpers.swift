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

    /// PCs, laptops and servers: DHCP client and a name server setting.
    public var isHost: Bool { self == .pc || self == .laptop || self == .server }
}

/// Node inspector tabs, in display order.
public enum InspectorTab: String, CaseIterable, Sendable {
    case interfaces = "Interfacce", ports = "Porte", routing = "Routing", services = "Servizi", tables = "Tabelle", app = "App"
}

public func inspectorTabs(for kind: DeviceKind) -> [InspectorTab] {
    switch kind {
    case .switch: [.ports, .tables]
    case .hub: [.ports]
    case .router, .server: [.interfaces, .routing, .services, .tables, .app]
    case .pc, .laptop: [.interfaces, .routing, .tables, .app]
    }
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
                     // A leased address (and the DHCP default route) belongs to the server, not to the design: only the mode is saved.
                     ifaces: n.ifaces.map { TopologyIface(name: $0.name, cidr: $0.mode == .dhcp ? nil : $0.cidr, mode: $0.mode) },
                     routes: n.routes.filter(\.isStatic).map { TopologyRoute(cidr: $0.dest, nextHop: $0.nextHop ?? "") },
                     powered: n.powered, nameServer: n.nameServer, dhcp: n.dhcpServer, dns: n.dnsRecords)
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

private let posix = Locale(identifier: "en_US_POSIX")

private func plain(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(posix))
}

/// One editable link property, in the units people type.
public enum LinkField: String, CaseIterable, Sendable {
    case bandwidth, delay, loss, queue

    public var label: String {
        switch self {
        case .bandwidth: "Banda (Mb/s)"
        case .delay: "Ritardo di propagazione (µs)"
        case .loss: "Perdita (%)"
        case .queue: "Coda (frame)"
        }
    }

    public func format(_ o: LinkOptions) -> String {
        switch self {
        case .bandwidth: plain(o.bandwidthBps / 1e6)
        case .delay: plain(Double(o.propDelayNs) / 1e3)
        case .loss: plain(o.lossRate * 100)
        case .queue: String(o.queueLimit)
        }
    }

    /// Turns text into the option; the engine checks the ranges.
    public func apply(_ text: String, to o: LinkOptions) throws -> LinkOptions {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite, abs(v) < 1e15, self != .queue || v == v.rounded() else {
            throw EngineError("Invalid number: \"\(text)\"")
        }
        var n = o
        switch self {
        case .bandwidth: n.bandwidthBps = v * 1e6
        case .delay: n.propDelayNs = Int((v * 1e3).rounded())
        case .loss: n.lossRate = v / 100
        case .queue: n.queueLimit = Int(v)
        }
        return n
    }
}

public func formatBandwidth(_ bps: Double) -> String {
    let units: [(Double, String)] = [(1e9, "Gb/s"), (1e6, "Mb/s"), (1e3, "kb/s")]
    let (scale, unit) = units.first { bps >= $0.0 } ?? (1, "b/s")
    return "\(plain(bps / scale)) \(unit)"
}

/// One editable DHCP server setting, in the units people type.
public enum DhcpField: String, CaseIterable, Sendable {
    case start, end, excluded, gateway, dns, lease

    public var label: String {
        switch self {
        case .start: "Inizio pool"
        case .end: "Fine pool"
        case .excluded: "Indirizzi esclusi"
        case .gateway: "Gateway (opzione 3)"
        case .dns: "Server DNS (opzione 6)"
        case .lease: "Durata lease (s)"
        }
    }

    public var placeholder: String {
        switch self {
        case .start: "10.0.0.100"
        case .end: "10.0.0.199"
        case .excluded: "10.0.0.120, 10.0.0.150-10.0.0.159"
        case .gateway, .dns: "nessuno"
        case .lease: "86400"
        }
    }

    public func format(_ c: DhcpConfig) -> String {
        switch self {
        case .start: c.start
        case .end: c.end
        case .excluded: c.excluded.joined(separator: ", ")
        case .gateway: c.gateway ?? ""
        case .dns: c.dns ?? ""
        case .lease: String(c.leaseS)
        }
    }

    /// Puts the typed text into the configuration; the engine checks addresses, ranges and the subnet.
    public func apply(_ text: String, to c: DhcpConfig) throws -> DhcpConfig {
        let t = text.trimmingCharacters(in: .whitespaces)
        var n = c
        switch self {
        case .start: n.start = t
        case .end: n.end = t
        case .excluded: n.excluded = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .gateway: n.gateway = t.isEmpty ? nil : t
        case .dns: n.dns = t.isEmpty ? nil : t
        case .lease:
            guard let v = Int(t) else { throw EngineError("Invalid number: \"\(text)\"") }
            n.leaseS = v
        }
        return n
    }
}

/// The line under a DHCP interface: RFC 2131 state, server and timers.
public func dhcpStatus(_ c: DhcpClientView) -> String {
    switch c.state {
    case "BOUND", "RENEWING", "REBINDING":
        "\(c.state) · server \(c.server ?? "-") · lease \(c.leaseS ?? 0) s" + (c.renewS.map { " · rinnovo tra \($0) s" } ?? "")
    case "INIT": "INIT · dispositivo spento"
    default: "\(c.state) · in attesa del server DHCP"
    }
}

public func leaseRows(_ leases: [LeaseRow]) -> [[String]] {
    leases.map { [$0.ip, $0.mac, "\($0.expiresS)s", $0.bound ? "assegnato" : "offerto"] }
}
