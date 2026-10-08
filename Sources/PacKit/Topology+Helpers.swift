import Foundation
import CoreGraphics
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
        case .cloud: "Cloud/ISP"
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
        case .cloud: "ISP"
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
    case .router, .server, .cloud: [.interfaces, .routing, .services, .tables, .app]
    case .pc, .laptop: [.interfaces, .routing, .tables, .app]
    }
}

/// Bottom panel tabs (spec §7.1 ⑤).
public enum BottomTab: String, CaseIterable, Sendable {
    case events = "Eventi", output = "Output app", metrics = "Metriche"
}

/// The App tab's traffic generator modes.
public enum TrafficKind: String, CaseIterable, Sendable {
    case tcp = "TCP", udp = "UDP"
}

/// Canvas tool (spec §7.1 ①): Sposta drags devices, Collega drags cables between them.
public enum Tool: String, CaseIterable, Sendable {
    case move = "Sposta", connect = "Collega"
}

/// Cable types in the palette (spec §7.1 ②).
public enum CableKind: String, CaseIterable, Sendable {
    case ethernet = "Ethernet 1 Gb/s", fiber = "Fibra 10 Gb/s", custom = "Personalizzato"

    /// Ethernet and Personalizzato start from the engine default (1 Gb/s, ~100 m of copper); fibre is 10 Gb/s over 1 km (5 µs).
    public var options: LinkOptions {
        switch self {
        case .ethernet, .custom: LinkOptions()
        case .fiber: LinkOptions(bandwidthBps: 10e9, propDelayNs: 5_000)
        }
    }
}

/// A router interface's NAT role (Servizi tab): IOS `ip nat inside` / `ip nat outside`.
public enum NatRole: String, CaseIterable, Sendable {
    case off = "—", inside, outside
}

public func natRole(_ config: NatConfig?, _ iface: String) -> NatRole {
    if config?.outside == iface { return .outside }
    return config?.inside.contains(iface) == true ? .inside : .off
}

extension FirewallAction {
    public var label: String {
        switch self {
        case .allow: "consenti"
        case .deny: "nega"
        }
    }
}

/// One rule as listed: "in Gi0/1 · nega tcp any → 203.0.113.1 porta 80".
public func ruleSummary(_ r: FirewallRule) -> String {
    "\(r.direction.rawValue) \(r.iface) · \(r.action.label) \(r.proto.rawValue) \(r.src) → \(r.dst)" + (r.port.map { " porta \($0)" } ?? "")
}

public func defaultName(_ kind: DeviceKind, existing nodes: [NodeView]) -> String {
    defaultName(kind, taken: Set(nodes.map(\.name)))
}

/// Lowest free "<prefix><n>" given the names already used (several devices added in one step).
func defaultName(_ kind: DeviceKind, taken: Set<String>) -> String {
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
                     ifaces: n.ifaces.map {
                         TopologyIface(name: $0.name, cidr: $0.mode == .dhcp ? nil : $0.cidr, mode: $0.mode,
                                       switchport: $0.switchport == PortConfig() ? nil : $0.switchport)
                     },
                     routes: n.routes.filter(\.isStatic).map { TopologyRoute(cidr: $0.dest, nextHop: $0.nextHop ?? "") },
                     powered: n.powered, nameServer: n.nameServer, dhcp: n.dhcpServer, dns: n.dnsRecords, sink: n.sink, nat: n.nat, firewall: n.firewall)
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

/// World rectangle holding every device box (`nodeSize`, centred on its position) plus `margin`: what Esporta immagine draws.
/// nil without devices.
public func exportBounds(_ centers: [Pos], nodeSize: CGSize, margin: Double) -> CGRect? {
    let boxes = centers.map { CGRect(x: $0.x - nodeSize.width / 2, y: $0.y - nodeSize.height / 2, width: nodeSize.width, height: nodeSize.height) }
    guard let first = boxes.first else { return nil }
    return boxes.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -margin, dy: -margin)
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
        case .excluded, .gateway, .dns: "nessuno"
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

/// One switch-port VLAN setting typed in the Porte tab.
public enum PortField: String, Sendable {
    case vlan, allowed, native

    public var label: String {
        switch self {
        case .vlan: "VLAN"
        case .allowed: "VLAN ammesse"
        case .native: "Nativa"
        }
    }

    public func format(_ c: PortConfig) -> String {
        switch self {
        case .vlan: String(c.vlan)
        case .allowed: c.allowed
        case .native: String(c.native)
        }
    }

    /// Puts the typed text into the settings; the engine checks the ranges, the list and the native VLAN.
    public func apply(_ text: String, to c: PortConfig) throws -> PortConfig {
        let t = text.trimmingCharacters(in: .whitespaces)
        var n = c
        if self == .allowed {
            n.allowed = t
            return n
        }
        guard let v = Int(t) else { throw EngineError("Invalid number: \"\(text)\"") }
        if self == .vlan { n.vlan = v } else { n.native = v }
        return n
    }
}

/// True when either end of the cable is a switch port in trunk mode: its label says "trunk".
public func isTrunk(_ link: LinkView, in nodes: [NodeView]) -> Bool {
    [link.a, link.b].contains { end in
        nodes.first { $0.id == end.node }?.ifaces.first { $0.name == end.iface }?.switchport?.mode == .trunk
    }
}

public func leaseRows(_ leases: [LeaseRow]) -> [[String]] {
    leases.map { [$0.ip, $0.mac, "\($0.expiresS)s", $0.bound ? "attivo" : "offerto"] }
}

private func milliseconds(_ ns: Int) -> String {
    String(format: "%.3f ms", Double(ns) / 1e6)
}

/// A flow's latest point: "9.49 Mb/s · RTT 1.235 ms · perdita 1.5%" (TCP) or with one-way latency and jitter (UDP).
public func flowSummary(_ s: FlowSample) -> String {
    var parts = [String(format: "%.2f Mb/s", s.bitsPerSecond / 1e6)]
    if let d = s.delayNs { parts.append((s.jitterNs == nil ? "RTT " : "latenza ") + milliseconds(d)) }
    if let j = s.jitterNs { parts.append("jitter " + milliseconds(j)) }
    parts.append(String(format: "perdita %.1f%%", s.lossPct))
    return parts.joined(separator: " · ")
}

/// One direction of a cable: "95% · coda 12 · drop 3".
public func directionSummary(_ d: DirectionSample) -> String {
    "\(Int((d.utilization * 100).rounded()))% · coda \(d.queued) · drop \(d.drops)"
}
