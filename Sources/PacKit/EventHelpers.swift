import PacEngine

extension Proto {
    public var label: String { self == .wifi ? "802.11" : rawValue.uppercased() }
}

extension EventKind {
    public var label: String { self == .state ? "STATO" : rawValue.uppercased() }
}

/// Simulated time with nanosecond digits: "1.000002672 s".
public func formatSimTime(_ ns: Int) -> String {
    let fraction = String(ns % 1_000_000_000)
    return "\(ns / 1_000_000_000)." + String(repeating: "0", count: 9 - fraction.count) + fraction + " s"
}

public func filterEvents(_ events: [EventView], protos: Set<Proto>, node: String?) -> [EventView] {
    events.filter { protos.contains($0.proto) && (node == nil || $0.node == node) }
}

/// Wall-clock seconds a PDU takes to cross a cable on screen (real transit takes microseconds).
public let FLIGHT_SECONDS = 0.4
/// ponytail: at most this many PDUs drawn at once; a storm shows only the newest
private let MAX_FLIGHTS = 40

/// A frame drawn moving along a cable: starts at its `tx`, leaves after its `rx`/`drop` at the far end and at least `FLIGHT_SECONDS`.
public struct Flight: Equatable, Identifiable, Sendable {
    /// Sequence number of the `tx` event.
    public let id: Int
    public let frameId: Int
    public let link: String
    /// Node at the sending end.
    public let from: String
    public let proto: Proto
    /// Wall-clock seconds (`Date.timeIntervalSinceReferenceDate`).
    public let start: Double
    public var arrived = false
}

/// Prefix of the air links' ids: never a cable's (cable ids come from `newId`).
private let AIR = "air:"

/// The dashed line from each associated station to its access point (spec M11 §7), as a link PDUs fly along. Not a cable: never in
/// the topology, never selectable.
public func airLinks(_ nodes: [NodeView]) -> [LinkView] {
    nodes.compactMap { n in
        // From the association on, the WPA2 handshake included (spec M11 §8): its frames fly along the line too.
        guard let s = n.station, s.state == .associated || s.state == .handshake, let ap = s.ap, let iface = n.ifaces.first,
              let radio = nodes.first(where: { $0.id == ap })?.ifaces.first(where: \.wireless) else { return nil }
        return LinkView(id: AIR + n.id, a: IfaceRef(node: n.id, iface: iface.name), b: IfaceRef(node: ap, iface: radio.name))
    }
}

public func updateFlights(_ flights: [Flight], with events: [EventView], links: [LinkView], now: Double) -> [Flight] {
    var out = flights
    for e in events {
        guard let frame = e.frameId else { continue }
        let here = links.filter { ($0.a.node == e.node && $0.a.iface == e.iface) || ($0.b.node == e.node && $0.b.iface == e.iface) }
        // An access point's radio reaches several stations: its frames are drawn from the station that receives them (spec M11 §7).
        let fromAp = here.first.map { $0.id.hasPrefix(AIR) && $0.b.node == e.node } ?? false
        if e.kind == .tx {
            if let cable = here.first, !fromAp { out.append(Flight(id: e.id, frameId: frame, link: cable.id, from: e.node, proto: e.proto, start: now)) }
        } else if let i = out.firstIndex(where: { f in !f.arrived && f.frameId == frame && f.from != e.node && here.contains { $0.id == f.link } }) {
            out[i].arrived = true
        } else if e.kind == .rx, let air = here.first, air.id.hasPrefix(AIR), air.a.node == e.node {
            out.append(Flight(id: e.id, frameId: frame, link: air.id, from: air.b.node, proto: e.proto, start: now, arrived: true))
        }
    }
    return pruneFlights(Array(out.suffix(MAX_FLIGHTS)), links: links, now: now)
}

/// Keeps flights still crossing the screen and whose cable still exists. A flight whose arrival never shows up
/// (skipped by the pull cap or evicted from the log) leaves after twice the flight time instead of animating forever.
public func pruneFlights(_ flights: [Flight], links: [LinkView], now: Double) -> [Flight] {
    flights.filter { f in
        let age = now - f.start
        return !(f.arrived && age >= FLIGHT_SECONDS) && age < 2 * FLIGHT_SECONDS && links.contains { $0.id == f.link }
    }
}

/// Fraction of the cable covered, from the sender.
public func flightProgress(_ f: Flight, now: Double) -> Double {
    min(max((now - f.start) / FLIGHT_SECONDS, 0), 1)
}
