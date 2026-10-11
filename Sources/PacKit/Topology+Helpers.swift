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
        case .printer: "Stampante"
        case .tv: "Smart TV"
        case .accessPoint: "Access point"
        case .tablet: "Tablet"
        case .smartphone: "Smartphone"
        case .modem: "Modem DSL"
        case .nas: "NAS"
        case .console: "Console"
        case .smartBulb: "Lampadina smart"
        case .thermostat: "Termostato"
        case .smartSpeaker: "Smart speaker"
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
        case .printer: "PRN"
        case .tv: "TV"
        case .accessPoint: "AP"
        case .tablet: "TAB"
        case .smartphone: "PHONE"
        case .modem: "MODEM"
        case .nas: "NAS"
        case .console: "CONSOLE"
        case .smartBulb: "LAMP"
        case .thermostat: "THERM"
        case .smartSpeaker: "SPK"
        }
    }

    public var hasIp: Bool { ![.switch, .hub, .accessPoint, .modem].contains(self) }

    /// PCs, laptops, servers, printers, Smart TVs, tablets and smartphones, and the home devices but the modem (spec M12): DHCP client
    /// and a name server setting.
    public var isHost: Bool { [.pc, .laptop, .server, .printer, .tv, .tablet, .smartphone, .nas, .console, .smartBulb, .thermostat, .smartSpeaker].contains(self) }
}

/// Palette entries that drop a plain server with a service already on (spec M10 §3); the raw value is the drag payload.
public enum ServerPreset: String, Sendable {
    case dns = "server-dns", dhcp = "server-dhcp"

    public var label: String { self == .dns ? "Server DNS" : "Server DHCP" }
}

/// Node inspector tabs, in display order.
public enum InspectorTab: String, CaseIterable, Sendable {
    case interfaces = "Interfacce", ports = "Porte", routing = "Routing", services = "Servizi", wifi = "Wi-Fi", tables = "Tabelle", app = "App"
}

public func inspectorTabs(for kind: DeviceKind) -> [InspectorTab] {
    switch kind {
    case .switch: [.ports, .services, .tables]
    case .hub: [.ports]
    case .router, .server, .cloud, .printer: [.interfaces, .routing, .services, .tables, .app]
    case .accessPoint: [.wifi, .tables]
    case .pc, .laptop, .tablet, .smartphone: [.interfaces, .routing, .wifi, .tables, .app]
    case .tv: [.interfaces, .routing, .tables, .app]
    // Spec M12: a modem shows its two ports; a NAS is a printer with disks; a console and the IoT devices have a PC's tabs.
    case .modem: [.ports]
    case .nas: inspectorTabs(for: .printer)
    case .console, .smartBulb, .thermostat, .smartSpeaker: inspectorTabs(for: .pc)
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

/// A router interface's part in RIP or OSPF (spec M8 §5): none, active, or passive (its network is advertised, it sends nothing).
public enum RoutingRole: String, CaseIterable, Sendable {
    case off = "—", active = "attiva", passive = "passiva"
}

public func ripRole(_ config: RipConfig?, _ iface: String) -> RoutingRole {
    config?.passive.contains(iface) == true ? .passive : config?.interfaces.contains(iface) == true ? .active : .off
}

public func ospfRole(_ config: OspfConfig?, _ iface: String) -> RoutingRole {
    config?.interfaces.first { $0.name == iface }.map { $0.passive ? .passive : .active } ?? .off
}

/// One row of Tabelle's routing tables (spec M8 §5, M9 §8): type (C, S, R, O, ND), destination, [distance/metric], next hop, interface.
public func routeColumns(_ r: RouteRow) -> [String] {
    let (type, distance) = r.metric.map { r.ospf ? ("O", "[110/\($0)]") : ("R", "[120/\($0)]") }
        ?? (r.ra ? ("ND", "[2/0]") : r.dhcp ? ("S", "[254/0]") : r.isStatic ? ("S", "[1/0]") : ("C", ""))
    return [type, r.dest, distance, (r.nextHop ?? "connessa") + (r.dhcp ? " (DHCP)" : ""), r.iface]
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

/// A cable never goes into a Wi-Fi interface (spec M11 §7). A modem's line faces a Cloud/ISP and its Ethernet port anything else,
/// the other port when that one is taken (spec M12 §2).
public func firstFreeIface(_ node: NodeView, toward peer: NodeView? = nil) -> String? {
    let free = node.ifaces.filter { !$0.linked && !$0.wireless }.map(\.name)
    guard node.kind == .modem, let peer else { return free.first }
    return free.first { ($0 == "dsl0") == (peer.kind == .cloud) } ?? free.first
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
                                       switchport: $0.switchport == PortConfig() ? nil : $0.switchport, ipv6: $0.ipv6Config)
                     },
                     routes: n.routes.filter(\.isStatic).map { TopologyRoute(cidr: $0.dest, nextHop: $0.nextHop ?? "") },
                     powered: n.powered, nameServer: n.nameServer, dhcp: n.dhcpServer, dns: n.dnsRecords, sink: n.sink, nat: n.nat, firewall: n.firewall,
                     stpPriorities: n.stpPriorities.isEmpty ? nil : n.stpPriorities, rip: n.rip, ospf: n.ospf,
                     ipv6Routing: n.ipv6Routing, rdnss: n.rdnss, accessPoint: n.accessPoint?.config, station: n.station?.config)
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

/// A DSL line's rates, down/up: "100/20 Mb/s" (spec M12 §2).
public func syncLabel(_ sync: (down: Double, up: Double)) -> String {
    "\(plain(sync.down / 1e6))/\(plain(sync.up / 1e6)) Mb/s"
}

/// A cable's rate on the canvas: a cable into a modem's line shows the line, capped by the cable (spec M12 §2).
public func cableRate(_ link: LinkView, in nodes: [NodeView]) -> String {
    let bps = link.options.bandwidthBps
    let dsl = [link.a, link.b].contains { end in end.iface == "dsl0" && nodes.contains { $0.id == end.node && $0.kind == .modem } }
    return dsl ? syncLabel((min(bps, VDSL2_SYNC.down), min(bps, VDSL2_SYNC.up))) : formatBandwidth(bps)
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

extension StationState {
    /// Tabelle's Wi-Fi state (spec M11 §1: "associato").
    public var label: String {
        switch self {
        case .idle: "nessuna rete"
        case .scanning: "scansione"
        case .notFound: "nessuna rete trovata"
        case .authenticating: "autenticazione"
        case .associating: "associazione"
        case .associated: "associato"
        }
    }
}

/// The line under a client's network (spec M11 §7): "Associato a pac-track · AP1 · canale 6", "Scansione…", "Nessuna rete trovata".
public func wifiStatus(_ s: StationView, in nodes: [NodeView]) -> String {
    switch s.state {
    case .idle: "Nessuna rete"
    case .scanning: "Scansione…"
    case .notFound: "Nessuna rete trovata"
    case .authenticating: "Autenticazione…"
    case .associating: "Associazione…"
    case .associated:
        "Associato a \(s.config.ssid) · \(nodes.first { $0.id == s.ap }?.name ?? "?") · canale \(s.channel.map(String.init) ?? "?")"
    }
}

/// Tabelle's Wi-Fi row of a client (spec M11 §7): state, SSID, BSSID, channel.
public func wifiRow(_ s: StationView) -> [String] {
    [s.state.label, s.config.ssid.isEmpty ? "-" : s.config.ssid, s.bssid ?? "-", s.channel.map(String.init) ?? "-"]
}

/// Tabelle of an access point (spec M11 §7): AID, MAC and the client's name.
public func associationRows(_ ap: AccessPointView, in nodes: [NodeView]) -> [[String]] {
    ap.clients.map { c in ["\(c.aid)", c.mac, nodes.first { $0.id == c.node }?.name ?? "?"] }
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

/// The device and port at the other end of the cable in `end` ("SW1 Gi0/2"); a subinterface answers for its physical interface.
/// nil while the interface is free.
public func peerLabel(_ end: IfaceRef, in s: Snapshot) -> String? {
    let physical = IfaceRef(node: end.node, iface: String(end.iface.split(separator: ".")[0]))
    guard let link = s.links.first(where: { $0.a == physical || $0.b == physical }) else { return nil }
    let peer = link.a == physical ? link.b : link.a
    return "\(s.nodes.first { $0.id == peer.node }?.name ?? "?") \(peer.iface)"
}

/// "192.168.1.10/24" as address and prefix; nil for anything else.
private func v4(_ cidr: String) -> (addr: UInt32, prefix: Int)? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let addr = try? parseIp(String(parts[0])), let prefix = Int(parts[1]) else { return nil }
    return (addr, prefix)
}

/// The devices and interfaces in the broadcast domain of `end`, in the engine's order.
private func segment(_ end: IfaceRef, in s: Snapshot) -> [(node: NodeView, iface: IfaceView)] {
    let refs = s.nodes.first { $0.id == end.node }?.ifaces.first { $0.name == end.iface }?.segment ?? []
    return refs.compactMap { r in s.nodes.first { $0.id == r.node }.flatMap { n in n.ifaces.first { $0.name == r.iface }.map { (n, $0) } } }
}

/// Up to three free host addresses, with their prefix, in the IPv4 subnets already used on the broadcast domain of `end` (from v1):
/// past the addresses assigned there (its own included) and the domain's DHCP pools. Empty while the domain has no address.
public func addressSuggestions(_ end: IfaceRef, in s: Snapshot) -> [String] {
    let peers = segment(end, in: s)
    let used = peers.compactMap { $0.iface.cidr.flatMap(v4) }
    let me = s.nodes.first { $0.id == end.node }
    let own = me?.ifaces.first { $0.name == end.iface }?.cidr.flatMap(v4)
    let taken = Set((used + [own].compactMap { $0 }).map(\.addr))
    // A DHCP server's own pool counts too: the segment leaves its node out.
    let pools = (peers.map(\.node.dhcpServer) + [me?.dhcpServer]).compactMap { $0.flatMap { c in try? (parseIp(c.start), parseIp(c.end)) } }
    var nets: [(net: UInt32, prefix: Int)] = []
    for u in used where u.prefix <= 30 {
        let net = (net: u.addr & UInt32.max << (32 - u.prefix), prefix: u.prefix)
        if !nets.contains(where: { $0 == net }) { nets.append(net) }
    }
    var out: [String] = []
    for (net, prefix) in nets {
        let broadcast = net | ~(UInt32.max << (32 - prefix))
        var a = net + 1
        while a < broadcast, out.count < 3 {
            if let pool = pools.first(where: { $0.0 <= a && a <= $0.1 }) {
                guard pool.1 < broadcast else { break }
                a = pool.1 + 1
                continue
            }
            if !taken.contains(a) { out.append("\(formatIp(a))/\(prefix)") }
            a += 1
        }
    }
    return out
}

/// The router and Cloud addresses on the broadcast domains of the node's interfaces (from v1), at most three.
public func gatewaySuggestions(_ node: String, in s: Snapshot) -> [String] {
    var out: [String] = []
    for iface in s.nodes.first(where: { $0.id == node })?.ifaces ?? [] {
        for peer in segment(IfaceRef(node: node, iface: iface.name), in: s) where [.router, .cloud].contains(peer.node.kind) {
            if let ip = peer.iface.cidr?.split(separator: "/").first.map(String.init), !out.contains(ip) { out.append(ip) }
        }
    }
    return Array(out.prefix(3))
}

/// Where a cable sits among those joining the same two devices (in cable order): 0 alone, else -(k-1)/2 … (k-1)/2, so the
/// canvas can spread parallel cables apart.
public func cableSlot(_ link: LinkView, in links: [LinkView]) -> Double {
    let pair = Set([link.a.node, link.b.node])
    let same = links.filter { Set([$0.a.node, $0.b.node]) == pair }
    return Double(same.firstIndex { $0.id == link.id } ?? 0) - Double(same.count - 1) / 2
}

/// The dot at a cable end (spec M7 §5): blocking if the port blocks in any VLAN, else listening or learning if it is on its way
/// in any; nil once it forwards in all of them (or is no switch port).
public func stpDot(_ end: IfaceRef, in nodes: [NodeView]) -> StpState? {
    let states = nodes.first { $0.id == end.node }?.stp.compactMap { $0.ports.first { $0.iface == end.iface }?.state } ?? []
    return states.contains(.blocking) ? .blocking : states.first { $0 != .forwarding }
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
