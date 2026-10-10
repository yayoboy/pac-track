/// state: a spanning-tree port state change (no frame; `SimEvent.note` says which).
public enum EventKind: String, Sendable {
    case tx, rx, drop, state
}

enum DropReason: String, Sendable {
    case queueFull = "queue-full"
    case loss
    case linkDown = "link-down"
    case ifaceDown = "iface-down"
    case noLink = "no-link"
    case arpTimeout = "arp-timeout"
    case arpPendingFull = "arp-pending-full"
    case noRoute = "no-route"
    case ttlExpired = "ttl-expired"
    case mtuExceeded = "mtu-exceeded"
    /// A firewall deny rule matched.
    case firewallRule = "firewall-rule"
    /// No firewall rule matched and the default policy denies.
    case firewallDefault = "firewall-default"
    /// A switch port refused a frame: tagged on an access port, or with a VLAN the trunk does not carry.
    case vlanNotAllowed = "vlan-not-allowed"
    /// A tagged frame reached a host, or a router with no subinterface for its VLAN.
    case unknownVlan = "unknown-vlan"
    /// A switch port in blocking, listening or learning state discards what it receives (802.1D).
    case stpDiscarding = "stp-discarding"
}

struct SimEvent: Sendable {
    var seq = 0
    var time: Int
    var kind: EventKind
    var node: String
    var iface: String? = nil
    var frame: EthernetFrame? = nil
    var packet: Ipv4Packet? = nil
    var reason: DropReason? = nil
    /// A spanning-tree state change: "VLAN 10: listening → learning".
    var note: String? = nil
    /// The protocol of a state change (nil: spanning tree).
    var proto: Proto? = nil
}

/// Ring buffer: keeps the latest `capacity` events.
final class EventLog {
    let capacity: Int
    private var buffer: [SimEvent] = []
    private var start = 0
    /// Events ever pushed, including those evicted.
    private(set) var total = 0

    init(capacity: Int = 100_000) {
        self.capacity = capacity
    }

    func push(_ event: SimEvent) {
        var e = event
        e.seq = total
        total += 1
        if buffer.count < capacity {
            buffer.append(e)
        } else {
            buffer[start] = e
            start = (start + 1) % capacity
        }
    }

    private var oldest: Int { total - buffer.count }

    /// Entries with `seq >= from` still in the buffer, oldest first.
    func since(_ from: Int) -> [SimEvent] {
        let first = max(from, oldest)
        guard first < total else { return [] }
        return (first..<total).map { buffer[(start + $0 - oldest) % buffer.count] }
    }

    func event(_ seq: Int) -> SimEvent? {
        guard seq >= oldest, seq < total else { return nil }
        return buffer[(start + seq - oldest) % buffer.count]
    }

    var all: [SimEvent] { Array(buffer[start...]) + buffer[..<start] }
    var size: Int { buffer.count }
}
