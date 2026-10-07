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

public enum Proto: String, CaseIterable, Sendable {
    case arp, icmp, udp
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
}

public struct RouteRow: Equatable, Sendable {
    public let dest: String
    public let nextHop: String?
    public let iface: String
    public let isStatic: Bool
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

public struct NodeView: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: DeviceKind
    public let name: String
    public let powered: Bool
    public let ifaces: [IfaceView]
    public let routes: [RouteRow]
    public let arp: [ArpRow]
    public let mac: [MacRow]
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
    public var cidr: String?
    public init(name: String, cidr: String?) {
        self.name = name
        self.cidr = cidr
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

public struct TopologyNode: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DeviceKind
    public var name: String
    public var pos: Pos
    public var ifaces: [TopologyIface]
    public var routes: [TopologyRoute]
    public var powered: Bool
    public init(id: String, kind: DeviceKind, name: String, pos: Pos, ifaces: [TopologyIface], routes: [TopologyRoute], powered: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.pos = pos
        self.ifaces = ifaces
        self.routes = routes
        self.powered = powered
    }

    /// Files written before M2b have no `powered`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(DeviceKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        pos = try c.decode(Pos.self, forKey: .pos)
        ifaces = try c.decode([TopologyIface].self, forKey: .ifaces)
        routes = try c.decode([TopologyRoute].self, forKey: .routes)
        powered = try c.decodeIfPresent(Bool.self, forKey: .powered) ?? true
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
