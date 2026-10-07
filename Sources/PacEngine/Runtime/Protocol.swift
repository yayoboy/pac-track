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
    public let ifaces: [IfaceView]
    public let routes: [RouteRow]
    public let arp: [ArpRow]
    public let mac: [MacRow]
}

public struct LinkView: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var a: IfaceRef
    public var b: IfaceRef
    public init(id: String, a: IfaceRef, b: IfaceRef) {
        self.id = id
        self.a = a
        self.b = b
    }
}

public struct AppView: Equatable, Identifiable, Sendable {
    public let id: Int
    public let node: String
    public let title: String
    public let lines: [String]
    public let done: Bool
}

public struct Snapshot: Equatable, Sendable {
    /// Strictly increasing per Runtime; lets the UI drop stale snapshots.
    public let version: Int
    public let seed: UInt32
    public let timeNs: Int
    public let running: Bool
    public let speed: Double
    public let nodes: [NodeView]
    public let links: [LinkView]
    public let apps: [AppView]

    public static let empty = Snapshot(version: 0, seed: 1, timeNs: 0, running: true, speed: 1, nodes: [], links: [], apps: [])
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
    public init(id: String, kind: DeviceKind, name: String, pos: Pos, ifaces: [TopologyIface], routes: [TopologyRoute]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.pos = pos
        self.ifaces = ifaces
        self.routes = routes
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
