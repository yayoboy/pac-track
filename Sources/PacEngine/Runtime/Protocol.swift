public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case pc, laptop, server, router, `switch`, hub
}

public struct IfaceRef: Codable, Hashable, Sendable {
    public var node: String
    public var iface: String
    public init(node: String, iface: String) {
        self.node = node
        self.iface = iface
    }
}

public struct Pos: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum SimMode: String, Codable, Sendable {
    /// The clock follows wall time × speed.
    case realtime
    /// The clock stands still; `step` runs to the next logged event, play steps slowly.
    case simulation
}

/// How a host interface gets its address.
public enum IfaceMode: String, Codable, Sendable {
    case `static`, dhcp
}

public enum Proto: String, CaseIterable, Sendable {
    case arp, icmp, dhcp, dns, udp, tcp
}

public enum Command: Sendable {
    case addNode(id: String, kind: DeviceKind, name: String)
    case removeNode(id: String)
    case rename(id: String, name: String)
    case connect(id: String, a: IfaceRef, b: IfaceRef)
    case disconnect(id: String)
    case setIp(node: String, iface: String, cidr: String?)
    case addRoute(node: String, cidr: String, nextHop: String)
    case removeRoute(node: String, cidr: String)
    case ping(node: String, target: String)
    case traceroute(node: String, target: String)
    case setIfaceMode(node: String, iface: String, mode: IfaceMode)
    /// Name server address typed by hand; nil or empty clears it.
    case setNameServer(node: String, ip: String?)
    /// nil turns the server off.
    case setDhcpServer(node: String, config: DhcpConfig?)
    /// nil turns the server off; the records replace the previous ones.
    case setDnsServer(node: String, records: [DnsRecord]?)
    case renewDhcp(node: String)
    case nslookup(node: String, name: String)
    case setMode(SimMode)
    case step
    case setPower(id: String, on: Bool)
    case updateLink(id: String, options: LinkOptions)
    case setLinkUp(id: String, up: Bool)
    case setRunning(Bool)
    case setSpeed(Double)
    case load(Topology)

    /// Default key used to show this command's error next to the right control.
    public var key: String {
        switch self {
        case .addNode: "addNode"
        case .removeNode: "removeNode"
        case .rename: "rename"
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .setIp: "setIp"
        case .addRoute: "addRoute"
        case .removeRoute: "removeRoute"
        case .ping: "ping"
        case .traceroute: "traceroute"
        case .setIfaceMode: "setIfaceMode"
        case .setNameServer: "setNameServer"
        case .setDhcpServer: "setDhcpServer"
        case .setDnsServer: "setDnsServer"
        case .renewDhcp: "renewDhcp"
        case .nslookup: "nslookup"
        case .setMode: "setMode"
        case .step: "step"
        case .setPower: "setPower"
        case .updateLink: "updateLink"
        case .setLinkUp: "setLinkUp"
        case .setRunning: "setRunning"
        case .setSpeed: "setSpeed"
        case .load: "load"
        }
    }
}

public struct IfaceView: Equatable, Sendable {
    public let name: String
    public let mac: String
    public let cidr: String?
    public let linked: Bool
    public let mode: IfaceMode
}

public struct RouteRow: Equatable, Sendable {
    public let dest: String
    public let nextHop: String?
    public let iface: String
    public let isStatic: Bool
    /// Default route learned from DHCP.
    public var dhcp = false
}

public struct ArpRow: Equatable, Sendable {
    public let ip: String
    public let mac: String
    public let iface: String
    public let ttlS: Int
}

public struct MacRow: Equatable, Sendable {
    public let mac: String
    public let iface: String
    public let ageS: Int
}

public struct LeaseRow: Equatable, Sendable {
    public let ip: String
    public let mac: String
    public let expiresS: Int
    /// False while only offered.
    public let bound: Bool
}

public struct DnsCacheRow: Equatable, Sendable {
    public let name: String
    public let ip: String
    public let ttlS: Int
}

/// A host's DHCP client: RFC 2131 state, server, seconds to expiry and to renewal (T1).
public struct DhcpClientView: Equatable, Sendable {
    public let state: String
    public let server: String?
    public let leaseS: Int?
    public let renewS: Int?

    public init(state: String, server: String?, leaseS: Int?, renewS: Int?) {
        self.state = state
        self.server = server
        self.leaseS = leaseS
        self.renewS = renewS
    }
}

/// One 100 ms point of a traffic flow (spec §5.6).
public struct FlowSample: Equatable, Sendable {
    public let timeNs: Int
    /// Goodput over the interval: bytes acknowledged (TCP) or received by the sink (UDP).
    public let bitsPerSecond: Double
    /// Smoothed RTT (TCP) or mean one-way latency of the interval's datagrams (UDP); nil until measured.
    public let delayNs: Int?
    /// RFC 3550 interarrival jitter; nil for TCP.
    public let jitterNs: Int?
    /// Retransmitted share of the segments sent (TCP) or lost share of the datagrams (UDP), in percent.
    public let lossPct: Double

    public init(timeNs: Int, bitsPerSecond: Double, delayNs: Int?, jitterNs: Int?, lossPct: Double) {
        self.timeNs = timeNs
        self.bitsPerSecond = bitsPerSecond
        self.delayNs = delayNs
        self.jitterNs = jitterNs
        self.lossPct = lossPct
    }
}

public struct NodeView: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: DeviceKind
    public let name: String
    public let powered: Bool
    public let ifaces: [IfaceView]
    public let routes: [RouteRow]
    public let arp: [ArpRow]
    public let mac: [MacRow]
    /// Name server typed by hand.
    public let nameServer: String?
    /// Name server learned from DHCP.
    public let learnedNameServer: String?
    /// Set while the host's interface is in DHCP mode.
    public let dhcpClient: DhcpClientView?
    /// nil while the DHCP server is off.
    public let dhcpServer: DhcpConfig?
    public let leases: [LeaseRow]
    /// nil while the DNS server is off.
    public let dnsRecords: [DnsRecord]?
    public let dnsCache: [DnsCacheRow]
}

public struct LinkView: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var a: IfaceRef
    public var b: IfaceRef
    public var options: LinkOptions
    /// False while a fault is simulated.
    public var up: Bool

    public init(id: String, a: IfaceRef, b: IfaceRef, options: LinkOptions = LinkOptions(), up: Bool = true) {
        self.id = id
        self.a = a
        self.b = b
        self.options = options
        self.up = up
    }

    /// Files written before M2b have no `options`/`up`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        a = try c.decode(IfaceRef.self, forKey: .a)
        b = try c.decode(IfaceRef.self, forKey: .b)
        options = try c.decodeIfPresent(LinkOptions.self, forKey: .options) ?? LinkOptions()
        up = try c.decodeIfPresent(Bool.self, forKey: .up) ?? true
    }
}

public struct AppView: Equatable, Identifiable, Sendable {
    public let id: Int
    public let node: String
    public let title: String
    public let lines: [String]
    public let done: Bool
}

/// One logged frame event, light enough to list thousands.
public struct EventView: Equatable, Identifiable, Sendable {
    /// Log sequence number, unique within one `Snapshot.epoch`.
    public let id: Int
    public let timeNs: Int
    public let kind: EventKind
    public let node: String
    public let iface: String?
    public let proto: Proto
    public let frameId: Int?
    /// Frame size (Wireshark convention), or packet size for L3 drops.
    public let bytes: Int
    public let info: String
    public let reason: String?

    public init(id: Int, timeNs: Int, kind: EventKind, node: String, iface: String?, proto: Proto,
                frameId: Int?, bytes: Int, info: String, reason: String?) {
        self.id = id
        self.timeNs = timeNs
        self.kind = kind
        self.node = node
        self.iface = iface
        self.proto = proto
        self.frameId = frameId
        self.bytes = bytes
        self.info = info
        self.reason = reason
    }
}

public struct PduField: Equatable, Sendable {
    public let name: String
    public let value: String
}

/// One header of a PDU, outermost first.
public struct PduLayer: Equatable, Sendable {
    public let title: String
    public let bytes: Int
    public let fields: [PduField]
}

/// A frame came back to the same L2 device: probably a loop.
public struct WarningView: Equatable, Identifiable, Sendable {
    public let id: Int
    public let node: String
    public let timeNs: Int
}

public struct Snapshot: Equatable, Sendable {
    /// Strictly increasing per Runtime; lets the UI drop stale snapshots.
    public internal(set) var version: Int
    public let seed: UInt32
    public let timeNs: Int
    public let running: Bool
    public let speed: Double
    public let mode: SimMode
    /// Bumped when the network is reloaded: event sequence numbers restart.
    public let epoch: Int
    /// Events ever logged in this epoch; the next one gets this sequence number.
    public let eventCount: Int
    public let nodes: [NodeView]
    public let links: [LinkView]
    public let apps: [AppView]
    public let warnings: [WarningView]

    public static let empty = Snapshot(version: 0, seed: 1, timeNs: 0, running: true, speed: 1, mode: .realtime, epoch: 0,
                                       eventCount: 0, nodes: [], links: [], apps: [], warnings: [])
}

public struct TopologyIface: Codable, Equatable, Sendable {
    public var name: String
    /// Always nil in DHCP mode: a leased address is never saved.
    public var cidr: String?
    public var mode: IfaceMode
    public init(name: String, cidr: String?, mode: IfaceMode = .`static`) {
        self.name = name
        self.cidr = cidr
        self.mode = mode
    }

    /// Files written before M3 have no `mode`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cidr = try c.decodeIfPresent(String.self, forKey: .cidr)
        mode = try c.decodeIfPresent(IfaceMode.self, forKey: .mode) ?? .`static`
    }
}

public struct TopologyRoute: Codable, Equatable, Sendable {
    public var cidr: String
    public var nextHop: String
    public init(cidr: String, nextHop: String) {
        self.cidr = cidr
        self.nextHop = nextHop
    }
}

/// DHCP server settings as typed in the inspector and saved in the project (addresses as text).
public struct DhcpConfig: Codable, Equatable, Sendable {
    public var start: String
    public var end: String
    /// Single addresses ("10.0.0.5") or ranges ("10.0.0.1-10.0.0.9").
    public var excluded: [String]
    public var gateway: String?
    public var dns: String?
    public var leaseS: Int

    public init(start: String, end: String, excluded: [String] = [], gateway: String? = nil, dns: String? = nil, leaseS: Int = 86_400) {
        self.start = start
        self.end = end
        self.excluded = excluded
        self.gateway = gateway
        self.dns = dns
        self.leaseS = leaseS
    }
}

/// An A record of a DNS server.
public struct DnsRecord: Codable, Equatable, Sendable {
    public static let defaultTtl = 3600
    public var name: String
    public var ip: String
    public var ttl: Int

    public init(name: String, ip: String, ttl: Int = DnsRecord.defaultTtl) {
        self.name = name
        self.ip = ip
        self.ttl = ttl
    }
}

public struct TopologyNode: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DeviceKind
    public var name: String
    public var pos: Pos
    public var ifaces: [TopologyIface]
    public var routes: [TopologyRoute]
    public var powered: Bool
    public var nameServer: String?
    public var dhcp: DhcpConfig?
    public var dns: [DnsRecord]?
    public init(id: String, kind: DeviceKind, name: String, pos: Pos, ifaces: [TopologyIface], routes: [TopologyRoute], powered: Bool = true,
                nameServer: String? = nil, dhcp: DhcpConfig? = nil, dns: [DnsRecord]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.pos = pos
        self.ifaces = ifaces
        self.routes = routes
        self.powered = powered
        self.nameServer = nameServer
        self.dhcp = dhcp
        self.dns = dns
    }

    /// Files written before M2b have no `powered`, before M3 no services.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(DeviceKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        pos = try c.decode(Pos.self, forKey: .pos)
        ifaces = try c.decode([TopologyIface].self, forKey: .ifaces)
        routes = try c.decode([TopologyRoute].self, forKey: .routes)
        powered = try c.decodeIfPresent(Bool.self, forKey: .powered) ?? true
        nameServer = try c.decodeIfPresent(String.self, forKey: .nameServer)
        dhcp = try c.decodeIfPresent(DhcpConfig.self, forKey: .dhcp)
        dns = try c.decodeIfPresent([DnsRecord].self, forKey: .dns)
    }
}

/// Project file format (`.ptk`).
public struct Topology: Codable, Equatable, Sendable {
    public var version = 1
    public var seed: UInt32
    public var nodes: [TopologyNode]
    public var links: [LinkView]
    public init(seed: UInt32 = 1, nodes: [TopologyNode] = [], links: [LinkView] = []) {
        self.seed = seed
        self.nodes = nodes
        self.links = links
    }

    public static let empty = Topology()
}

public let SPEEDS: [Double] = [0.1, 0.5, 1, 2, 5, 10, 100]
