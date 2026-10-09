/// `cloud`: an ISP edge router whose "Internet" answers by itself (spec §5.5).
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case pc, laptop, server, router, `switch`, hub, cloud
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

/// A switch port's 802.1Q role, IOS `switchport mode`.
public enum PortMode: String, Codable, CaseIterable, Sendable {
    case access, trunk
}

/// A switch port's VLAN settings as typed and saved (spec M7 §2): the access VLAN, or the trunk's allowed VLANs
/// ("all" or "10,20,30-35") and native VLAN. Every field is kept whatever the mode.
public struct PortConfig: Codable, Equatable, Sendable {
    public var mode: PortMode
    public var vlan: Int
    public var allowed: String
    public var native: Int
    /// IOS `spanning-tree portfast` (access ports only): straight to forwarding, and its changes send no TCN (spec M7 §4).
    public var portfast: Bool

    public init(mode: PortMode = .access, vlan: Int = 1, allowed: String = "all", native: Int = 1, portfast: Bool = false) {
        self.mode = mode
        self.vlan = vlan
        self.allowed = allowed
        self.native = native
        self.portfast = portfast
    }

    /// Files written before M7b have no `portfast`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(PortMode.self, forKey: .mode)
        vlan = try c.decode(Int.self, forKey: .vlan)
        allowed = try c.decode(String.self, forKey: .allowed)
        native = try c.decode(Int.self, forKey: .native)
        portfast = try c.decodeIfPresent(Bool.self, forKey: .portfast) ?? false
    }
}

/// A port's 802.1D role in one VLAN (alternate and backup ports are "blocked", as the spec's table shows them).
public enum StpRole: String, Sendable {
    case root, designated, blocked
}

/// A port's 802.1D state in one VLAN; a port that is down or outside the VLAN is not listed.
public enum StpState: String, Sendable {
    case blocking, listening, learning, forwarding
}

public struct StpPortRow: Equatable, Sendable {
    public let iface: String
    public let role: StpRole
    public let state: StpState
}

/// One PVST+ instance as `show spanning-tree vlan <n>` lists it.
public struct StpView: Equatable, Sendable {
    public let vlan: Int
    /// This switch's bridge priority for the VLAN (the VLAN is added to it in the bridge ID).
    public let priority: Int
    /// Root bridge ID, "priority/VLAN/MAC".
    public let root: String
    public let cost: Int
    /// nil on the root bridge.
    public let rootPort: String?
    public let ports: [StpPortRow]
}

/// A switch's bridge priority for one VLAN, saved when it is not the default 32768.
public struct StpPriority: Codable, Equatable, Sendable {
    public var vlan: Int
    public var priority: Int

    public init(vlan: Int, priority: Int) {
        self.vlan = vlan
        self.priority = priority
    }
}

public enum Proto: String, CaseIterable, Sendable {
    case arp, icmp, dhcp, dns, udp, tcp, stp
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
    case ping(node: String, target: String, options: PingOptions = PingOptions())
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
    /// Discard sink on TCP/UDP port 9 (servers only).
    case setSink(node: String, on: Bool)
    /// iperf3-style transfer of `bytes` to the target's sink.
    case trafficTcp(node: String, target: String, bytes: Int)
    /// iperf3-style constant-bitrate UDP stream to the target's sink.
    case trafficUdp(node: String, target: String, bitsPerSecond: Double, seconds: Int)
    /// NAT/PAT interface roles (routers only); nil turns NAT off. Any change forgets the translations.
    case setNat(node: String, config: NatConfig?)
    /// Firewall rules and default policy (routers only); nil turns it off. Any change forgets the tracked flows.
    case setFirewall(node: String, config: FirewallConfig?)
    case setMode(SimMode)
    case step
    case setPower(id: String, on: Bool)
    /// Switch size: 8, 24 or 48 ports; only free ports can go.
    case setPorts(id: String, count: Int)
    /// A switch port's 802.1Q role and VLANs (switches only); the addresses the port learned are flushed.
    case setSwitchport(node: String, iface: String, config: PortConfig)
    /// IOS `spanning-tree vlan <n> priority <p>` (switches only): 0…61440 in steps of 4096.
    case setStpPriority(node: String, vlan: Int, priority: Int)
    /// Router subinterface "<physical>.<VLAN>" (IOS `interface Gi0/0.10` + `encapsulation dot1q 10`), routers only.
    case addSubinterface(node: String, iface: String)
    /// Refused while NAT or a firewall rule names it.
    case removeSubinterface(node: String, iface: String)
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
        case .setSink: "setSink"
        case .trafficTcp: "trafficTcp"
        case .trafficUdp: "trafficUdp"
        case .setNat: "setNat"
        case .setFirewall: "setFirewall"
        case .setMode: "setMode"
        case .step: "step"
        case .setPower: "setPower"
        case .setPorts: "setPorts"
        case .setSwitchport: "setSwitchport"
        case .setStpPriority: "setStpPriority"
        case .addSubinterface: "addSubinterface"
        case .removeSubinterface: "removeSubinterface"
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
    /// A subinterface is linked when its physical interface is.
    public let linked: Bool
    public let mode: IfaceMode
    /// Switch ports only: the 802.1Q role.
    public let switchport: PortConfig?
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
    public let vlan: Int
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

/// One row of a node's TCP table, netstat style.
public struct TcpRow: Equatable, Sendable {
    public let local: String
    public let remote: String
    public let state: String
}

/// One row of a router's NAT table, `show ip nat translations` style (ICMP: the echo identifier as port).
public struct NatRow: Equatable, Sendable {
    public let proto: String
    public let insideLocal: String
    public let insideGlobal: String
    public let outside: String
    /// Seconds until the translation idles out.
    public let ttlS: Int
}

/// One direction of a cable over a 100 ms interval.
public struct DirectionSample: Equatable, Sendable {
    /// Share of the interval spent transmitting, 0…1.
    public let utilization: Double
    /// Frames waiting at the end of the interval.
    public let queued: Int
    /// Frames lost in the interval: full queue, random loss, fault.
    public let drops: Int

    public init(utilization: Double, queued: Int, drops: Int) {
        self.utilization = utilization
        self.queued = queued
        self.drops = drops
    }
}

public struct LinkSample: Equatable, Sendable {
    public let timeNs: Int
    /// From the link's `a` end to its `b` end, and back.
    public let ab: DirectionSample
    public let ba: DirectionSample

    public init(timeNs: Int, ab: DirectionSample, ba: DirectionSample) {
        self.timeNs = timeNs
        self.ab = ab
        self.ba = ba
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
    /// Discard sink on TCP/UDP port 9.
    public let sink: Bool
    /// Listening ports, then connections.
    public let tcp: [TcpRow]
    /// NAT interface roles; nil while NAT is off.
    public let nat: NatConfig?
    /// Live translations, oldest first.
    public let natTable: [NatRow]
    /// nil while the firewall is off.
    public let firewall: FirewallConfig?
    /// Switches: the PVST+ instances, by VLAN.
    public let stp: [StpView]
    /// Switches: the bridge priorities set away from 32768, by VLAN.
    public let stpPriorities: [StpPriority]
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
    /// One point per 100 ms for traffic flows; empty for the other apps.
    public let samples: [FlowSample]
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
    /// Speed the last Realtime tick actually reached; below `speed` when a tick ran out of its event budget (spec §6).
    public let effectiveSpeed: Double
    public let mode: SimMode
    /// Bumped when the network is reloaded: event sequence numbers restart.
    public let epoch: Int
    /// Events ever logged in this epoch; the next one gets this sequence number.
    public let eventCount: Int
    public let nodes: [NodeView]
    public let links: [LinkView]
    public let apps: [AppView]
    public let warnings: [WarningView]
    /// Per cable id, one point per 100 ms of simulated time (the last minute).
    public let linkSamples: [String: [LinkSample]]

    public static let empty = Snapshot(version: 0, seed: 1, timeNs: 0, running: true, speed: 1, effectiveSpeed: 1, mode: .realtime, epoch: 0,
                                       eventCount: 0, nodes: [], links: [], apps: [], warnings: [], linkSamples: [:])
}

public struct TopologyIface: Codable, Equatable, Sendable {
    public var name: String
    /// Always nil in DHCP mode: a leased address is never saved.
    public var cidr: String?
    public var mode: IfaceMode
    /// Switch ports whose VLAN role is not the default (access, VLAN 1); nil otherwise.
    public var switchport: PortConfig?
    public init(name: String, cidr: String?, mode: IfaceMode = .`static`, switchport: PortConfig? = nil) {
        self.name = name
        self.cidr = cidr
        self.mode = mode
        self.switchport = switchport
    }

    /// Files written before M3 have no `mode`, before M7 no `switchport`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cidr = try c.decodeIfPresent(String.self, forKey: .cidr)
        mode = try c.decodeIfPresent(IfaceMode.self, forKey: .mode) ?? .`static`
        switchport = try c.decodeIfPresent(PortConfig.self, forKey: .switchport)
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

/// NAT/PAT roles of a router's interfaces (IOS `ip nat inside` / `ip nat outside`); inside traffic leaves with the outside address.
public struct NatConfig: Codable, Equatable, Sendable {
    public var inside: [String]
    public var outside: String?

    public init(inside: [String] = [], outside: String? = nil) {
        self.inside = inside
        self.outside = outside
    }
}

public enum FirewallAction: String, Codable, CaseIterable, Sendable {
    case allow, deny
}

public enum FirewallDirection: String, Codable, CaseIterable, Sendable {
    case inbound = "in", outbound = "out"
}

public enum FirewallProto: String, Codable, CaseIterable, Sendable {
    case any, icmp, tcp, udp
}

/// One firewall rule, bound to an interface and a direction.
public struct FirewallRule: Codable, Equatable, Sendable {
    public var iface: String
    public var direction: FirewallDirection
    public var action: FirewallAction
    public var proto: FirewallProto
    /// "any", an address or a prefix ("10.0.0.0/24").
    public var src: String
    public var dst: String
    /// Destination port, TCP and UDP only; nil matches any.
    public var port: Int?

    public init(iface: String, direction: FirewallDirection, action: FirewallAction, proto: FirewallProto, src: String, dst: String,
                port: Int? = nil) {
        self.iface = iface
        self.direction = direction
        self.action = action
        self.proto = proto
        self.src = src
        self.dst = dst
        self.port = port
    }
}

/// Ordered rules (the first match decides) and the policy for packets no rule matches.
public struct FirewallConfig: Codable, Equatable, Sendable {
    public var rules: [FirewallRule]
    public var defaultAction: FirewallAction

    public init(rules: [FirewallRule] = [], defaultAction: FirewallAction = .allow) {
        self.rules = rules
        self.defaultAction = defaultAction
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
    public var sink: Bool
    public var nat: NatConfig?
    public var firewall: FirewallConfig?
    public var stpPriorities: [StpPriority]?
    public init(id: String, kind: DeviceKind, name: String, pos: Pos, ifaces: [TopologyIface], routes: [TopologyRoute], powered: Bool = true,
                nameServer: String? = nil, dhcp: DhcpConfig? = nil, dns: [DnsRecord]? = nil, sink: Bool = false,
                nat: NatConfig? = nil, firewall: FirewallConfig? = nil, stpPriorities: [StpPriority]? = nil) {
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
        self.sink = sink
        self.nat = nat
        self.firewall = firewall
        self.stpPriorities = stpPriorities
    }

    /// Files written before M2b have no `powered`, before M3 no services, before M4 no `sink`, before M5 no `nat`/`firewall`, before M7b no `stpPriorities`.
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
        sink = try c.decodeIfPresent(Bool.self, forKey: .sink) ?? false
        nat = try c.decodeIfPresent(NatConfig.self, forKey: .nat)
        firewall = try c.decodeIfPresent(FirewallConfig.self, forKey: .firewall)
        stpPriorities = try c.decodeIfPresent([StpPriority].self, forKey: .stpPriorities)
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
/// Switch sizes offered in the Porte tab (spec §5.5).
public let SWITCH_PORTS = [8, 24, 48]
/// Bridge priorities offered in the switch's Servizi tab (spec M7 §5): multiples of 4096, the low 12 bits being the VLAN.
public let STP_PRIORITIES = Array(stride(from: 0, through: 61440, by: 4096))
