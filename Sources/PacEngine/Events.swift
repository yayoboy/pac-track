public enum EventKind: String, Sendable {
    case tx, rx, drop
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
