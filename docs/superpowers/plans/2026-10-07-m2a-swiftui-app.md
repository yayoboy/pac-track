# M2a — SwiftUI app: build, configure and test a network (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS document app (`.ptk`) in which you drag devices onto a canvas, cable them, set IPs and routes in an inspector, run ping/traceroute, read live ARP/MAC/routing tables and output, with undo/redo and native open/save/autosave.

**Architecture:** `PacEngine` gains a public façade — `Command`/`Snapshot`/`Topology` value types and a `Runtime` that applies commands to the engine. `PacKit` hosts the `Simulation` actor (owns a `Runtime`), the `@MainActor @Observable Editor` (all user actions, undo/redo, positions, selection, errors) and the `PacDocument`. `PacTrack` is a thin SwiftUI layer (palette, custom canvas, inspector, output, toolbar, menus) plus a `--selftest` mode that drives the real `Editor` + `Simulation`, renders the window offscreen to PNG and exits 0/1.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM — Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2: §4, §6, §7, §8, §9, §10 — milestone M2a). Supersedes `docs/superpowers/plans/2026-10-07-m2a-app-shell.md` (Electron).

## Global Constraints

- Run every `swift`/`scripts/*.sh` command **outside the sandbox**; run tests with `scripts/test.sh` (bare `swift test` runs zero tests with CLT).
- The UI never holds engine objects — only `Snapshot` values and string ids (engine nodes are owned by their `Sim`; a reload frees them).
- Never store `SimTimer`s or closures that capture their owner (retain cycles); cancel by state checks.
- Every network change goes through `Editor.edit` (one undo step per user action); ping/traceroute/play/speed go through `Editor.run`.
- The editor accepts only snapshots newer than the one it shows (`Snapshot.version`), so a late clock tick can never roll back an edit.
- User-facing copy Italian; code, comments, tests, commits English. Colors only from `Theme`.
- Snapshots list nodes/links in creation order and table rows sorted — never in `Dictionary` order.
- Commit trailer:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FbFogmKCbqCctTUt5TujDV
  ```

## Review Focus

1. **Clock tick racing an edit** (tick snapshot taken before the edit resumes after it) → UI must not roll back; undo memento must include the edit. Pinned: `Snapshot.version` + `Editor.accept` test (Task 3).
2. **Removing a node while its frames are on the wire** → no crash. Pinned in Task 2 (`removing a node with frames in flight…`).
3. **Corrupt or foreign `.ptk`** → readable error, nothing loaded. Pinned in Task 3 (`ProjectFile` tests) and Task 2 (atomic `load`).
4. **Deleting a node with cables** → one undo step restores node and cables. Pinned in Task 3.
5. **Cmd+Z while typing in a text field** → undoes the text, not the network. Pinned by the menu routing in Task 4 and the manual checklist (Task 7).

## File Structure

```
Package.swift                              + PacKit, PacTrack, PacKitTests
Resources/Info.plist                       app bundle plist (document type .ptk)
scripts/bundle.sh                          build/PacTrack.app (release, ad-hoc signed)
scripts/selftest.sh                        debug build + `PacTrack --selftest`
Sources/PacEngine/Runtime/Protocol.swift   Command, Snapshot & views, Topology (public, Sendable, Codable)
Sources/PacEngine/Runtime/Runtime.swift    Command → engine; snapshot builder; clock
Sources/PacKit/Topology+Helpers.swift      names, ports, topology <-> snapshot, snap
Sources/PacKit/ProjectFile.swift           JSON encode/decode + PacDocument
Sources/PacKit/Simulation.swift            EngineClient protocol + Simulation actor
Sources/PacKit/Editor.swift                Editor (actions, undo/redo, clock)
Sources/PacTrack/main.swift                entry: app or --selftest
Sources/PacTrack/PacTrackApp.swift         DocumentGroup, MainView, toolbar, menu commands
Sources/PacTrack/Theme.swift               colors, fonts, device symbols
Sources/PacTrack/MainContent.swift         layout
Sources/PacTrack/PaletteView.swift
Sources/PacTrack/CanvasView.swift          canvas, links, pan/zoom, drop, menus
Sources/PacTrack/DeviceNodeView.swift      node, drag, cable handle, node menu
Sources/PacTrack/InspectorView.swift
Sources/PacTrack/OutputPanel.swift
Sources/PacTrack/Controls.swift            CommitField, ErrorLine, TableSection
Sources/PacTrack/SelfTest.swift            scripted end-to-end check + PNG
Tests/PacEngineTests/RuntimeTests.swift
Tests/PacKitTests/*.swift
docs/manual-checks/m2a.md                  gestures and menus checklist
```

---

### Task 1: Engine views, route removal, cable disconnect

**Files:**
- Modify: `Sources/PacEngine/Link.swift`, `Sources/PacEngine/L3/RoutingTable.swift`, `Sources/PacEngine/L3/Arp.swift`, `Sources/PacEngine/Devices/Switch.swift`
- Test: `Tests/PacEngineTests/LinkTests.swift`, `Tests/PacEngineTests/RoutingTests.swift`, `Tests/PacEngineTests/IpTests.swift`, `Tests/PacEngineTests/L2Tests.swift`

**Interfaces:**
- Produces: `Link.disconnect()`; `struct RouteView { isStatic: Bool; network: UInt32; prefix: Int; nextHop: UInt32?; iface: String }`; `RoutingTable.removeStatic(_ cidr:) throws`; `RoutingTable.view() -> [RouteView]` (connected first, then statics in insertion order); `struct ArpEntry { ip: UInt32; mac: Mac; iface: String; expiresAt: Int }`; `Arp.entries() -> [ArpEntry]` (sorted by ip); `Switch.macTable() -> [(mac: Mac, iface: String, ageNs: Int)]` (sorted by mac)

- [ ] **Step 1: Write the failing tests**

Append inside `struct LinkTests` in `Tests/PacEngineTests/LinkTests.swift`:

```swift
    @Test func disconnectFreesBothInterfacesAndLaterFramesFindNoCable() throws {
        let (sim, a, b, link) = try pair()
        link.disconnect()
        #expect(try a.iface("eth0").link == nil)
        #expect(try b.iface("eth0").link == nil)
        try a.sendRaw()
        sim.run(MS)
        #expect(drops(sim, .noLink) == 1)
        let c = Probe(sim: sim, id: "C")
        _ = try Link(sim: sim, try a.iface("eth0"), try c.iface("eth0"))
    }

    @Test func framesOnTheWireOrQueuedWhenTheCableIsPulledNeverArrive() throws {
        let (sim, a, b, link) = try pair()
        try a.sendRaw()
        try a.sendRaw()
        link.disconnect()
        sim.run(MS)
        #expect(b.got.isEmpty)
        #expect(sim.log.all.filter { $0.kind == .tx }.count == 1)
    }
```

Append inside `struct RoutingTests` in `Tests/PacEngineTests/RoutingTests.swift`:

```swift
    @Test func listsAndRemovesStaticRoutes() throws {
        let (_, _, rt) = try setup()
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        let rows = { rt.view().map { "\($0.isStatic ? "static" : "connected") \(formatIp($0.network))/\($0.prefix) \($0.nextHop.map(formatIp) ?? "-") \($0.iface)" } }
        #expect(rows() == [
            "connected 10.0.1.0/24 - eth0",
            "connected 10.0.12.0/30 - eth1",
            "static 10.0.2.0/24 10.0.12.2 eth1",
        ])
        try rt.removeStatic("10.0.2.7/24")
        #expect(try hop(rt, "10.0.2.1") == nil)
        #expect(rows().count == 2)
    }
```

Append inside `struct IpTests` in `Tests/PacEngineTests/IpTests.swift`:

```swift
    @Test func listsLiveArpEntriesUntilTheyExpire() throws {
        let (sim, _, a, b) = try lan()
        a.sendPacket(try parseIp("10.0.0.2"), echoRequest())
        sim.run(MS)
        let entries = a.arp.entries()
        #expect(entries.map { "\(formatIp($0.ip)) \($0.mac) \($0.iface)" } == ["10.0.0.2 \(try b.iface("eth0").mac) eth0"])
        sim.run(301 * S)
        #expect(a.arp.entries().isEmpty)
    }
```

Append inside `struct L2Tests` in `Tests/PacEngineTests/L2Tests.swift`:

```swift
    @Test func listsTheMacTableWithoutAgedEntries() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B"])
        try p[0].sendRaw()
        sim.run(MS)
        #expect(sw.macTable().map { "\($0.mac) \($0.iface)" } == ["\(try p[0].iface("eth0").mac) Gi0/1"])
        sim.run(301 * S)
        #expect(sw.macTable().isEmpty)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `scripts/test.sh`
Expected: build FAIL — `value of type 'Link' has no member 'disconnect'` (and `view`, `entries`, `macTable`).

- [ ] **Step 3: Implement**

In `Sources/PacEngine/Link.swift` add after `peer(_:)`:

```swift
    /// Pulls the cable: both interfaces become free, frames in flight are lost.
    func disconnect() {
        up = false
        a.link = nil
        b.link = nil
    }
```

and in `startTx` replace

```swift
            if dir.queue.isEmpty {
                dir.busy = false
            } else {
                startTx(from, dir, dir.queue.removeFirst())
            }
```

with

```swift
            if up, !dir.queue.isEmpty {
                startTx(from, dir, dir.queue.removeFirst())
            } else {
                dir.busy = false
                dir.queue.removeAll()
            }
```

In `Sources/PacEngine/L3/RoutingTable.swift` add after `struct NextHop`:

```swift
struct RouteView: Equatable {
    let isStatic: Bool
    let network: UInt32
    let prefix: Int
    let nextHop: UInt32?
    let iface: String
}
```

and after `addStatic`:

```swift
    func removeStatic(_ cidr: String) throws {
        let c = try parseCidr(cidr)
        let network = networkOf(c.addr, c.prefix)
        statics.removeAll { $0.network == network && $0.prefix == c.prefix }
    }

    func view() -> [RouteView] {
        let connected = interfaces().compactMap { i -> RouteView? in
            guard i.up, let c = i.ipv4 else { return nil }
            return RouteView(isStatic: false, network: networkOf(c.addr, c.prefix), prefix: c.prefix, nextHop: nil, iface: i.name)
        }
        let statics = statics.map {
            RouteView(isStatic: true, network: $0.network, prefix: $0.prefix, nextHop: $0.nextHop, iface: connectedFor($0.nextHop)?.iface.name ?? "-")
        }
        return connected + statics
    }
```

In `Sources/PacEngine/L3/Arp.swift` add after the constants:

```swift
struct ArpEntry: Equatable {
    let ip: UInt32
    let mac: Mac
    let iface: String
    let expiresAt: Int
}
```

and after `lookup(_:)`:

```swift
    func entries() -> [ArpEntry] {
        cache.filter { node.sim.now < $0.value.expiresAt }
            .map { ArpEntry(ip: $0.key, mac: $0.value.mac, iface: $0.value.iface.name, expiresAt: $0.value.expiresAt) }
            .sorted { $0.ip < $1.ip }
    }
```

In `Sources/PacEngine/Devices/Switch.swift` add after `lookup(_:)`:

```swift
    func macTable() -> [(mac: Mac, iface: String, ageNs: Int)] {
        table.keys.sorted().compactMap { mac in
            guard let iface = lookup(mac), let seen = table[mac]?.seen else { return nil }
            return (mac, iface.name, sim.now - seen)
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 79 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat(engine): add table views, route removal and cable disconnect"
```

---

### Task 2: Public protocol and Runtime

**Files:**
- Create: `Sources/PacEngine/Runtime/Protocol.swift`, `Sources/PacEngine/Runtime/Runtime.swift`
- Modify: `Sources/PacEngine/EngineError.swift` (public)
- Test: `Tests/PacEngineTests/RuntimeTests.swift`

**Interfaces:**
- Consumes: Task 1 views; `Ping`, `Traceroute`, devices.
- Produces (all `public`, `Sendable`):
  - `EngineError(_ message:)`, `.message`
  - `enum DeviceKind: String, Codable, CaseIterable { pc, laptop, server, router, switch, hub }`
  - `struct IfaceRef: Codable, Hashable { node; iface }`, `struct Pos: Codable, Equatable { x: Double; y: Double }`
  - `enum Command { addNode(id:kind:name:), removeNode(id:), rename(id:name:), connect(id:a:b:), disconnect(id:), setIp(node:iface:cidr: String?), addRoute(node:cidr:nextHop:), removeRoute(node:cidr:), ping(node:target:), traceroute(node:target:), setRunning(Bool), setSpeed(Double), load(Topology) }` with `var key: String`
  - `IfaceView { name; mac; cidr: String?; linked }`, `RouteRow { dest; nextHop: String?; iface; isStatic }`, `ArpRow { ip; mac; iface; ttlS }`, `MacRow { mac; iface; ageS }`, `NodeView: Identifiable { id; kind; name; ifaces; routes; arp; mac }`, `LinkView: Codable, Identifiable { id; a; b }`, `AppView: Identifiable { id: Int; node; title; lines; done }`
  - `struct Snapshot { version: Int; seed: UInt32; timeNs: Int; running: Bool; speed: Double; nodes; links; apps; static let empty }`
  - `struct Topology: Codable, Equatable { version = 1; seed: UInt32; nodes: [TopologyNode]; links: [LinkView]; static let empty }`, `TopologyNode { id; kind; name; pos; ifaces: [TopologyIface]; routes: [TopologyRoute] }`, `TopologyIface { name; cidr: String? }`, `TopologyRoute { cidr; nextHop }`
  - `let SPEEDS: [Double]`
  - `final class Runtime { init(seed: UInt32 = 1); running; speed; func handle(_ cmd: Command) throws; func advance(wallMs: Double); func snapshot() -> Snapshot }`

- [ ] **Step 1: Make `EngineError` public**

Replace `Sources/PacEngine/EngineError.swift` with:

```swift
/// A user-facing validation error. `message` matches the M1 engine's texts.
public struct EngineError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
```

- [ ] **Step 2: Write the protocol types**

`Sources/PacEngine/Runtime/Protocol.swift`:

```swift
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
```

- [ ] **Step 3: Write the failing test**

`Tests/PacEngineTests/RuntimeTests.swift`:

```swift
import Testing
@testable import PacEngine

private func lanRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "b", kind: .pc, name: "PC2"))
    try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/1")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "b", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2")))
    try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
    try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.2/24"))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct RuntimeTests {
    @Test func buildsANetworkFromCommandsAndReportsItInTheSnapshot() throws {
        let s = try lanRuntime().snapshot()
        #expect(s.nodes.map { "\($0.name):\($0.kind.rawValue)" } == ["PC1:pc", "PC2:pc", "SW1:switch"])
        #expect(s.nodes[0].ifaces.map { "\($0.name) \($0.cidr ?? "-") \($0.linked)" } == ["eth0 10.0.0.1/24 true"])
        #expect(s.nodes[0].routes == [RouteRow(dest: "10.0.0.0/24", nextHop: nil, iface: "eth0", isStatic: false)])
        #expect(s.links.map(\.id) == ["l1", "l2"])
        #expect(s.links[1] == LinkView(id: "l2", a: IfaceRef(node: "b", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2")))
    }

    @Test func runsPingAsAnAppAndFillsArpAndMacTables() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 15_000)
        let s = rt.snapshot()
        #expect(s.apps.count == 1)
        #expect(s.apps[0].node == "a" && s.apps[0].title == "ping 10.0.0.2" && s.apps[0].done)
        #expect(s.apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(s.nodes[0].arp.map(\.ip) == ["10.0.0.2"])
        #expect(s.nodes[2].mac.count == 2)
    }

    @Test func advancesSimulatedTimeByWallTimeTimesSpeedClampedAndOnlyWhileRunning() throws {
        let rt = Runtime()
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().timeNs == 50_000_000)
        try rt.handle(.setSpeed(10))
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().timeNs == 550_000_000)
        rt.advance(wallMs: 600_000) // ten minutes asleep: only 100 ms of wall time count
        #expect(rt.snapshot().timeNs == 1_550_000_000)
        try rt.handle(.setRunning(false))
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().timeNs == 1_550_000_000)
        expectError("Invalid speed") { try rt.handle(.setSpeed(0)) }
    }

    @Test func rejectsInvalidCommandsWithClearErrorsAndNoSideEffects() throws {
        let rt = try lanRuntime()
        expectError("Invalid IPv4") { try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.300/24")) }
        expectError("already exists") { try rt.handle(.addNode(id: "a", kind: .pc, name: "X")) }
        expectError("already connected") {
            try rt.handle(.connect(id: "l3", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/3")))
        }
        expectError("no IP stack") { try rt.handle(.ping(node: "s", target: "10.0.0.1")) }
        expectError("Unknown node") { try rt.handle(.removeNode(id: "zz")) }
        expectError("empty") { try rt.handle(.rename(id: "a", name: "  ")) }
        #expect(rt.snapshot().nodes[0].ifaces[0].cidr == "10.0.0.1/24")
        #expect(rt.snapshot().links.count == 2)
    }

    @Test func removingANodeRemovesItsCablesAndStopsItsApps() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        try rt.handle(.removeNode(id: "s"))
        try rt.handle(.removeNode(id: "a"))
        let s = rt.snapshot()
        #expect(s.links.isEmpty)
        #expect(s.nodes.map { $0.ifaces[0].linked } == [false])
        #expect(s.apps[0].done)
    }

    @Test func removingANodeWithFramesInFlightIsSafe() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        rt.advance(wallMs: 0.0005) // 500 ns: the first ARP frame is still on the wire
        try rt.handle(.removeNode(id: "s"))
        runFor(rt, wallMs: 3_000)
        #expect(rt.snapshot().nodes.map(\.name) == ["PC1", "PC2"])
    }

    @Test func clearsAnAddressAndManagesStaticRoutes() throws {
        let rt = try lanRuntime()
        try rt.handle(.addRoute(node: "a", cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        #expect(rt.snapshot().nodes[0].routes.last == RouteRow(dest: "0.0.0.0/0", nextHop: "10.0.0.254", iface: "eth0", isStatic: true))
        try rt.handle(.removeRoute(node: "a", cidr: "0.0.0.0/0"))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: nil))
        #expect(rt.snapshot().nodes[0].routes.isEmpty)
        #expect(rt.snapshot().nodes[0].ifaces[0].cidr == nil)
    }

    @Test func snapshotVersionsStrictlyIncrease() throws {
        let rt = try lanRuntime()
        let v1 = rt.snapshot().version
        rt.advance(wallMs: 10)
        #expect(rt.snapshot().version > v1)
    }

    @Test func loadsATopologyAtomically() throws {
        let rt = try lanRuntime()
        let t = Topology(seed: 7, nodes: [
            TopologyNode(id: "r", kind: .router, name: "R1", pos: Pos(x: 0, y: 0), ifaces: [
                TopologyIface(name: "Gi0/0", cidr: "10.0.1.1/24"), TopologyIface(name: "Gi0/1", cidr: nil),
            ], routes: []),
            TopologyNode(id: "h", kind: .pc, name: "H1", pos: Pos(x: 0, y: 0),
                         ifaces: [TopologyIface(name: "eth0", cidr: "10.0.1.10/24")],
                         routes: [TopologyRoute(cidr: "0.0.0.0/0", nextHop: "10.0.1.1")]),
        ], links: [LinkView(id: "x", a: IfaceRef(node: "h", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0"))])
        rt.advance(wallMs: 50)
        try rt.handle(.load(t))
        let s = rt.snapshot()
        #expect(s.seed == 7 && s.timeNs == 0)
        #expect(s.nodes.map(\.name) == ["R1", "H1"])
        #expect(s.nodes[1].routes.last?.nextHop == "10.0.1.1")

        var badLink = t
        badLink.links = [LinkView(id: "y", a: IfaceRef(node: "h", iface: "eth9"), b: IfaceRef(node: "r", iface: "Gi0/1"))]
        expectError("no interface eth9") { try rt.handle(.load(badLink)) }
        var badVersion = t
        badVersion.version = 2
        expectError("Unsupported or corrupt") { try rt.handle(.load(badVersion)) }
        #expect(rt.snapshot().nodes.map(\.name) == ["R1", "H1"])
    }
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `scripts/test.sh --filter RuntimeTests`
Expected: build FAIL — `cannot find 'Runtime' in scope`.

- [ ] **Step 5: Implement**

`Sources/PacEngine/Runtime/Runtime.swift`:

```swift
private let MAX_APPS = 20
/// Longest wall-clock gap simulated in one call; longer gaps (sleep, hidden window) are dropped.
private let MAX_STEP_MS = 100.0

private enum Program {
    case ping(Ping)
    case trace(Traceroute)

    var lines: [String] {
        switch self {
        case .ping(let p): p.result.lines
        case .trace(let t): t.result.lines
        }
    }

    var done: Bool {
        switch self {
        case .ping(let p): p.result.done
        case .trace(let t): t.result.done
        }
    }

    func stop() {
        switch self {
        case .ping(let p): p.stop()
        case .trace(let t): t.stop()
        }
    }
}

private struct App {
    let id: Int
    let node: String
    let title: String
    let program: Program
}

/// Owns one simulation and translates protocol commands into engine calls. Not thread-safe: confine it (PacKit's `Simulation` actor).
public final class Runtime {
    public private(set) var running = true
    public private(set) var speed = 1.0
    private var sim: Sim
    private var seed: UInt32
    private var nodes: [String: (node: Node, kind: DeviceKind)] = [:]
    private var nodeOrder: [String] = []
    private var links: [String: Link] = [:]
    private var linkOrder: [String] = []
    private var apps: [App] = []
    private var appId = 0
    private var version = 0

    public init(seed: UInt32 = 1) {
        self.seed = seed
        sim = Sim(seed: seed)
    }

    public func handle(_ cmd: Command) throws {
        switch cmd {
        case let .addNode(id, kind, name):
            guard nodes[id] == nil else { throw EngineError("Node \(id) already exists") }
            let node = create(id, kind)
            node.name = name
            nodes[id] = (node, kind)
            nodeOrder.append(id)
        case let .removeNode(id):
            let node = try get(id)
            for linkId in linkOrder where links[linkId]!.a.node === node || links[linkId]!.b.node === node {
                links[linkId]!.disconnect()
                links[linkId] = nil
            }
            linkOrder.removeAll { links[$0] == nil }
            for app in apps where app.node == id { app.program.stop() }
            nodes[id] = nil
            nodeOrder.removeAll { $0 == id }
        case let .rename(id, name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw EngineError("Name cannot be empty") }
            try get(id).name = trimmed
        case let .connect(id, a, b):
            guard links[id] == nil else { throw EngineError("Link \(id) already exists") }
            links[id] = try Link(sim: sim, try get(a.node).iface(a.iface), try get(b.node).iface(b.iface))
            linkOrder.append(id)
        case let .disconnect(id):
            guard let link = links[id] else { throw EngineError("Unknown link \(id)") }
            link.disconnect()
            links[id] = nil
            linkOrder.removeAll { $0 == id }
        case let .setIp(node, iface, cidr):
            let ip = try ipNode(node)
            if let cidr = cidr?.trimmingCharacters(in: .whitespaces), !cidr.isEmpty {
                try ip.setIp(iface, cidr)
            } else {
                try ip.iface(iface).ipv4 = nil
            }
        case let .addRoute(node, cidr, nextHop):
            try ipNode(node).routes.addStatic(cidr.trimmingCharacters(in: .whitespaces), nextHop.trimmingCharacters(in: .whitespaces))
        case let .removeRoute(node, cidr):
            try ipNode(node).routes.removeStatic(cidr)
        case let .ping(node, target):
            let t = target.trimmingCharacters(in: .whitespaces)
            start(node, "ping \(t)", .ping(try Ping(node: try ipNode(node), target: t)))
        case let .traceroute(node, target):
            let t = target.trimmingCharacters(in: .whitespaces)
            start(node, "traceroute \(t)", .trace(try Traceroute(node: try ipNode(node), target: t)))
        case let .setRunning(value):
            running = value
        case let .setSpeed(value):
            guard value > 0 && value <= 1000 else { throw EngineError("Invalid speed: \(value)") }
            speed = value
        case let .load(topology):
            try load(topology)
        }
    }

    public func advance(wallMs: Double) {
        guard running else { return }
        sim.run(Int((min(wallMs, MAX_STEP_MS) * Double(MS) * speed).rounded()))
    }

    public func snapshot() -> Snapshot {
        version += 1
        let now = sim.now
        let nodeViews = nodeOrder.map { id -> NodeView in
            let (node, kind) = nodes[id]!
            let ip = node as? IpNode
            return NodeView(
                id: id,
                kind: kind,
                name: node.name,
                ifaces: node.interfaces.map {
                    IfaceView(name: $0.name, mac: $0.mac, cidr: $0.ipv4.map { "\(formatIp($0.addr))/\($0.prefix)" }, linked: $0.link != nil)
                },
                routes: ip?.routes.view().map {
                    RouteRow(dest: "\(formatIp($0.network))/\($0.prefix)", nextHop: $0.nextHop.map(formatIp), iface: $0.iface, isStatic: $0.isStatic)
                } ?? [],
                arp: ip?.arp.entries().map {
                    ArpRow(ip: formatIp($0.ip), mac: $0.mac, iface: $0.iface, ttlS: ($0.expiresAt - now + S - 1) / S)
                } ?? [],
                mac: (node as? Switch)?.macTable().map { MacRow(mac: $0.mac, iface: $0.iface, ageS: $0.ageNs / S) } ?? []
            )
        }
        let linkViews = linkOrder.map { id in
            let l = links[id]!
            return LinkView(id: id, a: IfaceRef(node: l.a.node.id, iface: l.a.name), b: IfaceRef(node: l.b.node.id, iface: l.b.name))
        }
        let appViews = apps.map { AppView(id: $0.id, node: $0.node, title: $0.title, lines: $0.program.lines, done: $0.program.done) }
        return Snapshot(version: version, seed: seed, timeNs: now, running: running, speed: speed, nodes: nodeViews, links: linkViews, apps: appViews)
    }

    private func create(_ id: String, _ kind: DeviceKind) -> Node {
        switch kind {
        case .pc, .laptop, .server: Host(sim: sim, id: id)
        case .router: Router(sim: sim, id: id)
        case .switch: Switch(sim: sim, id: id)
        case .hub: Hub(sim: sim, id: id)
        }
    }

    private func get(_ id: String) throws -> Node {
        guard let entry = nodes[id] else { throw EngineError("Unknown node \(id)") }
        return entry.node
    }

    private func ipNode(_ id: String) throws -> IpNode {
        let node = try get(id)
        guard let ip = node as? IpNode else { throw EngineError("\(node.name) has no IP stack") }
        return ip
    }

    private func start(_ node: String, _ title: String, _ program: Program) {
        appId += 1
        apps.append(App(id: appId, node: node, title: title, program: program))
        if apps.count > MAX_APPS { apps.removeFirst().program.stop() }
    }

    /// Builds the new network aside and swaps it in only if every step succeeds.
    private func load(_ t: Topology) throws {
        guard t.version == 1 else { throw EngineError("Unsupported or corrupt project file") }
        let next = Runtime(seed: t.seed)
        for n in t.nodes {
            try next.handle(.addNode(id: n.id, kind: n.kind, name: n.name))
            for i in n.ifaces where i.cidr != nil { try next.handle(.setIp(node: n.id, iface: i.name, cidr: i.cidr)) }
        }
        for l in t.links { try next.handle(.connect(id: l.id, a: l.a, b: l.b)) }
        for n in t.nodes {
            for r in n.routes { try next.handle(.addRoute(node: n.id, cidr: r.cidr, nextHop: r.nextHop)) }
        }
        for app in apps { app.program.stop() }
        sim = next.sim
        seed = next.seed
        nodes = next.nodes
        nodeOrder = next.nodeOrder
        links = next.links
        linkOrder = next.linkOrder
        apps = []
    }
}
```

Then add `import Foundation` as the first line of `Runtime.swift` (needed by `trimmingCharacters(in:)`).

- [ ] **Step 6: Run tests**

Run: `scripts/test.sh`
Expected: 88 tests passed, no warnings in the build output.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "feat(engine): add public command protocol and simulation runtime"
```

---

### Task 3: PacKit — Simulation actor, Editor, helpers and project file

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PacKit/Topology+Helpers.swift`, `Sources/PacKit/ProjectFile.swift`, `Sources/PacKit/Simulation.swift`, `Sources/PacKit/Editor.swift`
- Test: `Tests/PacKitTests/HelpersTests.swift`, `Tests/PacKitTests/ProjectFileTests.swift`, `Tests/PacKitTests/EditorTests.swift`

**Interfaces:**
- Consumes: Task 2 public API.
- Produces:
  - helpers: `DeviceKind.label`, `DeviceKind.hasIp`, `defaultName(_:existing:)`, `firstFreeIface(_:)`, `firstIp(_:)`, `gatewayOf(_:)`, `makeTopology(_:_:)`, `positions(of:)`, `sameNetwork(_:_:)`, `newId()`, `snap(_:grid:)`
  - `enum ProjectFile { static func encode(_:) throws -> Data; static func decode(_:) throws -> Topology }`; `UTType.pacTrackProject`; `struct PacDocument: FileDocument { var topology }`
  - `protocol EngineClient: Sendable { func send(_ cmd: Command) async throws -> Snapshot; func advance(wallMs: Double) async -> Snapshot }`; `actor Simulation: EngineClient`
  - `enum Selection: Equatable { node(String), link(String) }`; `struct EditorError: Equatable { key; message }`
  - `@MainActor @Observable final class Editor { snapshot; positions; selection; error; canUndo; canRedo; onChange; init(client:); current; load(_:) async; run(_:key:) async -> Bool; edit(_:key:) async -> Bool (single and array); addDevice(_:at:) async; connect(_:_:) async; remove(nodes:links:) async; deleteSelection() async; select(_:); setPosition(_:_:); moveStart(); moveEnd(); undo() async; redo() async; tick(wallMs:) async; runClock() async }`

- [ ] **Step 1: Add the PacKit target**

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacTrack",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PacEngine"),
        .target(name: "PacKit", dependencies: ["PacEngine"]),
        .testTarget(name: "PacEngineTests", dependencies: ["PacEngine"]),
        .testTarget(name: "PacKitTests", dependencies: ["PacKit", "PacEngine"]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`Tests/PacKitTests/HelpersTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@Suite struct HelpersTests {
    private func snapshot() throws -> Snapshot {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "c", kind: .pc, name: "PC3"))
        try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "r", iface: "Gi0/0"), b: IfaceRef(node: "a", iface: "eth0")))
        try rt.handle(.setIp(node: "r", iface: "Gi0/1", cidr: "10.0.0.1/24"))
        try rt.handle(.addRoute(node: "r", cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        return rt.snapshot()
    }

    @Test func picksTheLowestFreeDefaultNamePerKind() throws {
        let nodes = try snapshot().nodes
        #expect(defaultName(.pc, existing: nodes) == "PC2")
        #expect(defaultName(.router, existing: nodes) == "R2")
        #expect(defaultName(.switch, existing: nodes) == "SW1")
    }

    @Test func findsFreePortsFirstIpAndGateway() throws {
        let nodes = try snapshot().nodes
        let r = nodes[2]
        #expect(firstFreeIface(r) == "Gi0/1")
        #expect(firstIp(r) == "10.0.0.1")
        #expect(gatewayOf(r) == "10.0.0.254")
        #expect(firstFreeIface(nodes[0]) == nil)
    }

    @Test func comparesTopologiesIgnoringPositions() throws {
        let s = try snapshot()
        let a = makeTopology(s, [:])
        let moved = makeTopology(s, ["a": Pos(x: 9, y: 9)])
        var renamed = a
        renamed.nodes[0].name = "X"
        #expect(sameNetwork(a, moved))
        #expect(!sameNetwork(a, renamed))
        #expect(positions(of: moved)["a"] == Pos(x: 9, y: 9))
    }

    @Test func snapsToTheGrid() {
        #expect(snap(Pos(x: 20, y: 6)) == Pos(x: 14, y: 0))
        #expect(snap(Pos(x: 22, y: -8)) == Pos(x: 28, y: -14))
    }
}
```

`Tests/PacKitTests/ProjectFileTests.swift`:

```swift
import Foundation
import PacEngine
import Testing
@testable import PacKit

@Suite struct ProjectFileTests {
    @Test func roundTripsATopology() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "a", kind: .switch, name: "SW1", pos: Pos(x: 1, y: 2), ifaces: [TopologyIface(name: "Gi0/1", cidr: nil)], routes: []),
        ])
        #expect(try ProjectFile.decode(try ProjectFile.encode(t)) == t)
    }

    @Test func rejectsGarbageAndUnknownVersions() throws {
        expectError("Not a Pac-Track project file") { _ = try ProjectFile.decode(Data("{ not json".utf8)) }
        expectError("Not a Pac-Track project file") { _ = try ProjectFile.decode(Data(#"{"version":1,"seed":1,"nodes":[{"kind":"toaster"}],"links":[]}"#.utf8)) }
        expectError("Unsupported or corrupt") { _ = try ProjectFile.decode(Data(#"{"version":9,"seed":1,"nodes":[],"links":[]}"#.utf8)) }
    }
}

func expectError(_ fragment: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected an error containing \"\(fragment)\"", sourceLocation: sourceLocation)
    } catch {
        #expect("\(error)".contains(fragment), "got: \(error)", sourceLocation: sourceLocation)
    }
}
```

`Tests/PacKitTests/EditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

/// Records every command and forwards it to a real Simulation.
private actor Recording: EngineClient {
    let simulation = Simulation()
    private(set) var sent: [String] = []

    func send(_ cmd: Command) async throws -> Snapshot {
        sent.append(cmd.key)
        return try await simulation.send(cmd)
    }

    func advance(wallMs: Double) async -> Snapshot {
        await simulation.advance(wallMs: wallMs)
    }

    func clear() { sent = [] }
}

@MainActor
@Suite struct EditorTests {
    let client = Recording()
    let editor: Editor
    let origin = Pos(x: 0, y: 0)

    init() {
        editor = Editor(client: client)
    }

    private var names: [String] { editor.snapshot.nodes.map(\.name) }
    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func addsDevicesWithDefaultNamesPositionsAndSelection() async {
        await editor.addDevice(.pc, at: Pos(x: 10, y: 20))
        await editor.addDevice(.pc, at: Pos(x: 30, y: 20))
        await editor.addDevice(.router, at: origin)
        #expect(names == ["PC1", "PC2", "R1"])
        #expect(editor.positions[node("PC2").id] == Pos(x: 30, y: 20))
        #expect(editor.selection == .node(node("R1").id))
        #expect(editor.canUndo)
    }

    @Test func connectsThroughTheFirstFreePortsAndReportsFullDevices() async {
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("PC1").id, node("SW1").id)
        #expect(editor.snapshot.links.first.map { "\($0.a.iface)-\($0.b.iface)" } == "eth0-Gi0/1")
        await editor.connect(node("PC1").id, node("PC2").id)
        #expect(editor.error == EditorError(key: "connect", message: "PC1 has no free port"))
        #expect(editor.snapshot.links.count == 1)
    }

    @Test func aFailedEditShowsItsErrorAndAddsNoHistory() async {
        await editor.addDevice(.pc, at: origin)
        await editor.undo()
        await editor.redo()
        let ok = await editor.edit(.setIp(node: node("PC1").id, iface: "eth0", cidr: "nope"), key: "ip")
        #expect(!ok)
        #expect(editor.error == EditorError(key: "ip", message: "Invalid CIDR: \"nope\""))
        await editor.undo()
        #expect(names.isEmpty) // the only undo step left is the add
    }

    @Test func undoesAndRedoesAddingADeviceKeepingIdAndPosition() async {
        await editor.addDevice(.pc, at: Pos(x: 5, y: 6))
        let id = node("PC1").id
        await editor.undo()
        #expect(names.isEmpty)
        await editor.redo()
        #expect(node("PC1").id == id)
        #expect(editor.positions[id] == Pos(x: 5, y: 6))
    }

    @Test func deletingANodeWithCablesIsOneStepAndUndoRestoresEverything() async {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("PC1").id, node("SW1").id)
        await editor.connect(node("PC2").id, node("SW1").id)
        let links = editor.snapshot.links
        await editor.remove(nodes: [node("SW1").id], links: links.map(\.id))
        #expect(names == ["PC1", "PC2"])
        #expect(editor.snapshot.links.isEmpty)
        await editor.undo()
        #expect(names == ["SW1", "PC1", "PC2"])
        #expect(editor.snapshot.links == links)
    }

    @Test func undoingAMoveRestoresPositionsWithoutReloadingTheNetwork() async {
        await editor.addDevice(.pc, at: origin)
        let id = node("PC1").id
        editor.moveStart()
        editor.setPosition(id, Pos(x: 100, y: 50))
        editor.moveEnd()
        await client.clear()
        await editor.undo()
        #expect(editor.positions[id] == origin)
        #expect(await client.sent.isEmpty)
    }

    @Test func aClickWithoutMovementAddsNoHistoryAndANewEditClearsRedo() async {
        await editor.addDevice(.pc, at: origin)
        editor.moveStart()
        editor.moveEnd()
        await editor.undo()
        #expect(names.isEmpty && !editor.canUndo && editor.canRedo)
        await editor.addDevice(.hub, at: origin)
        #expect(!editor.canRedo)
    }

    @Test func reportsEveryNetworkChangeToTheDocument() async {
        var saved: [Topology] = []
        editor.onChange = { saved.append($0) }
        await editor.addDevice(.pc, at: origin)
        _ = await editor.run(.setRunning(false))
        await editor.undo()
        #expect(saved.map(\.nodes.count) == [1, 0])
    }

    @Test func loadsADocumentAndClearsHistory() async throws {
        await editor.addDevice(.router, at: Pos(x: 1, y: 2))
        let t = editor.current
        let fresh = Editor(client: Simulation())
        await fresh.load(t)
        #expect(fresh.current == t)
        #expect(!fresh.canUndo)
        var broken = t
        broken.version = 7
        await fresh.load(broken)
        #expect(fresh.error?.key == "file")
        #expect(fresh.current == t)
    }

    @Test func ignoresSnapshotsOlderThanTheOneShown() async {
        await editor.addDevice(.pc, at: origin)
        let shown = editor.snapshot
        editor.accept(Snapshot.empty)
        #expect(editor.snapshot == shown)
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `scripts/test.sh --filter PacKitTests`
Expected: build FAIL — `no such module 'PacKit'` / missing sources.

- [ ] **Step 4: Implement**

`Sources/PacKit/Topology+Helpers.swift`:

```swift
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
                     ifaces: n.ifaces.map { TopologyIface(name: $0.name, cidr: $0.cidr) },
                     routes: n.routes.filter(\.isStatic).map { TopologyRoute(cidr: $0.dest, nextHop: $0.nextHop ?? "") })
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
```

`Sources/PacKit/ProjectFile.swift`:

```swift
import Foundation
import PacEngine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static let pacTrackProject = UTType(exportedAs: "com.pactrack.project")
}

public enum ProjectFile {
    public static func encode(_ t: Topology) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(t)
    }

    public static func decode(_ data: Data) throws -> Topology {
        let t: Topology
        do {
            t = try JSONDecoder().decode(Topology.self, from: data)
        } catch {
            throw EngineError("Not a Pac-Track project file")
        }
        guard t.version == 1 else { throw EngineError("Unsupported or corrupt project file") }
        return t
    }
}

public struct PacDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.pacTrackProject] }
    public var topology: Topology

    public init(topology: Topology = .empty) {
        self.topology = topology
    }

    public init(configuration: ReadConfiguration) throws {
        topology = try ProjectFile.decode(configuration.file.regularFileContents ?? Data())
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ProjectFile.encode(topology))
    }
}
```

`Sources/PacKit/Simulation.swift`:

```swift
import PacEngine

public protocol EngineClient: Sendable {
    /// Applies `cmd` and returns the snapshot that includes it; throws the engine's error.
    func send(_ cmd: Command) async throws -> Snapshot
    func advance(wallMs: Double) async -> Snapshot
}

/// Confines one `Runtime` (and its engine objects) to an actor.
public actor Simulation: EngineClient {
    private let runtime = Runtime()

    public init() {}

    public func send(_ cmd: Command) throws -> Snapshot {
        try runtime.handle(cmd)
        return runtime.snapshot()
    }

    public func advance(wallMs: Double) -> Snapshot {
        runtime.advance(wallMs: wallMs)
        return runtime.snapshot()
    }
}
```

`Sources/PacKit/Editor.swift`:

```swift
import Observation
import PacEngine

public enum Selection: Equatable, Sendable {
    case node(String)
    case link(String)
}

public struct EditorError: Equatable, Sendable {
    /// Which control shows the error (e.g. "ip:<node>:<iface>", "connect", "file").
    public let key: String
    public let message: String
}

/// All user actions on one document. Holds presentation state only; the network lives in the `EngineClient`.
@MainActor
@Observable
public final class Editor {
    public private(set) var snapshot = Snapshot.empty
    public var positions: [String: Pos] = [:]
    public private(set) var selection: Selection?
    public private(set) var error: EditorError?
    private var past: [Topology] = []
    private var future: [Topology] = []
    @ObservationIgnored private var pendingMove: Topology?
    private let client: any EngineClient
    /// Called with the new topology after every network change (document autosave hooks in here).
    @ObservationIgnored public var onChange: ((Topology) -> Void)?

    private static let historyLimit = 100

    public init(client: any EngineClient) {
        self.client = client
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var current: Topology { makeTopology(snapshot, positions) }

    /// Accepts only snapshots newer than the one shown, so a late clock tick never rolls back an edit.
    func accept(_ s: Snapshot) {
        if s.version > snapshot.version { snapshot = s }
    }

    private func fail(_ key: String, _ error: any Error) {
        self.error = EditorError(key: key, message: (error as? EngineError)?.message ?? "\(error)")
    }

    private func remember(_ before: Topology) {
        past = Array((past + [before]).suffix(Self.historyLimit))
        future = []
        onChange?(current)
    }

    /// Opens a document: replaces the network and clears history. Never counts as an edit.
    public func load(_ t: Topology) async {
        do {
            accept(try await client.send(.load(t)))
            positions = PacKit.positions(of: t)
            past = []
            future = []
            selection = nil
            error = nil
        } catch {
            fail("file", error)
        }
    }

    /// Sends a command that does not change the topology (apps, clock).
    @discardableResult
    public func run(_ cmd: Command, key: String? = nil) async -> Bool {
        do {
            accept(try await client.send(cmd))
            error = nil
            return true
        } catch {
            fail(key ?? cmd.key, error)
            return false
        }
    }

    /// Sends topology changes as a single undo step.
    @discardableResult
    public func edit(_ cmds: [Command], key: String? = nil) async -> Bool {
        let before = current
        for (i, cmd) in cmds.enumerated() {
            guard await run(cmd, key: key) else {
                if i > 0 { remember(before) }
                return false
            }
        }
        remember(before)
        return true
    }

    @discardableResult
    public func edit(_ cmd: Command, key: String? = nil) async -> Bool {
        await edit([cmd], key: key)
    }

    public func select(_ s: Selection?) {
        selection = s
    }

    public func setPosition(_ id: String, _ pos: Pos) {
        positions[id] = pos
    }

    public func addDevice(_ kind: DeviceKind, at pos: Pos) async {
        let id = newId()
        positions[id] = pos
        if await edit(.addNode(id: id, kind: kind, name: defaultName(kind, existing: snapshot.nodes))) {
            selection = .node(id)
        }
    }

    public func connect(_ aId: String, _ bId: String) async {
        guard aId != bId, let a = snapshot.nodes.first(where: { $0.id == aId }), let b = snapshot.nodes.first(where: { $0.id == bId }) else { return }
        guard let ia = firstFreeIface(a), let ib = firstFreeIface(b) else {
            error = EditorError(key: "connect", message: "\(firstFreeIface(a) == nil ? a.name : b.name) has no free port")
            return
        }
        await edit(.connect(id: newId(), a: IfaceRef(node: aId, iface: ia), b: IfaceRef(node: bId, iface: ib)), key: "connect")
    }

    /// Deletes nodes and cables in one undo step (cables of deleted nodes go with them).
    public func remove(nodes nodeIds: [String], links linkIds: [String]) async {
        let gone = Set(nodeIds)
        let cables = linkIds.filter { id in snapshot.links.contains { $0.id == id && !gone.contains($0.a.node) && !gone.contains($0.b.node) } }
        let cmds = cables.map { Command.disconnect(id: $0) } + nodeIds.map { Command.removeNode(id: $0) }
        if !cmds.isEmpty { await edit(cmds) }
        selection = nil
    }

    public func deleteSelection() async {
        switch selection {
        case .node(let id): await remove(nodes: [id], links: [])
        case .link(let id): await remove(nodes: [], links: [id])
        case nil: break
        }
    }

    public func moveStart() {
        pendingMove = current
    }

    public func moveEnd() {
        if let before = pendingMove, before != current { remember(before) }
        pendingMove = nil
    }

    private func restore(_ t: Topology) async {
        if !sameNetwork(t, current), let s = try? await client.send(.load(t)) { accept(s) }
        positions = PacKit.positions(of: t)
        selection = nil
        error = nil
    }

    public func undo() async {
        guard let previous = past.popLast() else { return }
        future.insert(current, at: 0)
        await restore(previous)
        onChange?(current)
    }

    public func redo() async {
        guard !future.isEmpty else { return }
        let next = future.removeFirst()
        past.append(current)
        await restore(next)
        onChange?(current)
    }

    public func tick(wallMs: Double) async {
        accept(await client.advance(wallMs: wallMs))
    }

    /// Advances the simulation every 50 ms until the calling task is cancelled.
    public func runClock() async {
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            let now = clock.now
            await tick(wallMs: (now - last) / .milliseconds(1))
            last = now
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: 104 tests passed (88 + 4 helpers + 2 project file + 10 editor); build shows no warnings.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/PacKit Tests/PacKitTests
git commit -m "feat(kit): add simulation actor, editor with undo/redo and project document"
```

---

### Task 4: App shell — document app, toolbar, menus, bundle and selftest

**Files:**
- Modify: `Package.swift`, `.gitignore`
- Create: `Resources/Info.plist`, `scripts/bundle.sh`, `scripts/selftest.sh`, `Sources/PacTrack/main.swift`, `Sources/PacTrack/PacTrackApp.swift`, `Sources/PacTrack/Theme.swift`, `Sources/PacTrack/MainContent.swift`, `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: `Editor`, `Simulation`, `PacDocument` (Task 3)
- Produces: `PacTrack --selftest <png>` (exit 0 = all checks pass, prints `SELFTEST OK` or `SELFTEST FAIL: …`); `Theme`, `DeviceKind.symbol`; `MainContent(editor:)`; `FocusedValues.editor`
- Note: UI tasks have no unit tests (no Xcode). Their RED/GREEN evidence is the selftest PNG, read with the Read tool before and after the change, plus the selftest's editor-level checks.

- [ ] **Step 1: Write the failing selftest run**

`scripts/selftest.sh`:

```sh
#!/bin/sh
# End-to-end check without Xcode: drives the real Editor + Simulation, renders the window to PNG.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/selftest.png}"
mkdir -p "$(dirname "$OUT")"
swift build --product PacTrack
exec .build/debug/PacTrack --selftest "$OUT"
```

Run: `chmod +x scripts/selftest.sh && scripts/selftest.sh`
Expected: FAIL — `error: no product named 'PacTrack'`.

- [ ] **Step 2: Add the app target, plist and bundle script**

In `Package.swift` add to `targets` (after the PacKit target):

```swift
        .executableTarget(name: "PacTrack", dependencies: ["PacKit", "PacEngine"]),
```

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PacTrack</string>
    <key>CFBundleIdentifier</key><string>com.pactrack.app</string>
    <key>CFBundleName</key><string>Pac-Track</string>
    <key>CFBundleDisplayName</key><string>Pac-Track</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Progetto Pac-Track</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.pactrack.project</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.pactrack.project</string>
            <key>UTTypeDescription</key><string>Progetto Pac-Track</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>ptk</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
```

`scripts/bundle.sh`:

```sh
#!/bin/sh
# Builds build/PacTrack.app (release, ad-hoc signed) without Xcode.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product PacTrack
APP=build/PacTrack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PacTrack "$APP/Contents/MacOS/PacTrack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "$APP"
```

Run: `chmod +x scripts/bundle.sh`

- [ ] **Step 3: Implement theme, layout, app, menus and selftest**

`Sources/PacTrack/Theme.swift`:

```swift
import PacEngine
import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x1E1F22)
    static let panel = Color(hex: 0x2B2D30)
    static let border = Color(hex: 0x393B40)
    static let borderStrong = Color(hex: 0x43454A)
    static let fg = Color(hex: 0xBCBEC4)
    static let fgStrong = Color(hex: 0xDFE1E5)
    static let muted = Color(hex: 0x6F737A)
    static let accent = Color(hex: 0x3574F0)
    static let ok = Color(hex: 0x5FB865)
    static let err = Color(hex: 0xE5507A)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let small = Font.system(size: 10)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension DeviceKind {
    var symbol: String {
        switch self {
        case .pc: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .server: "server.rack"
        case .router: "wifi.router"
        case .switch: "rectangle.connected.to.line.below"
        case .hub: "circle.hexagongrid"
        }
    }
}
```

`Sources/PacTrack/MainContent.swift`:

```swift
import PacKit
import SwiftUI

/// Window content without the toolbar (the selftest renders exactly this).
struct MainContent: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            Theme.panel.frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                Theme.bg
                Divider()
                Theme.panel.frame(height: 170)
            }
            Divider()
            Theme.panel.frame(width: 290)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
```

`Sources/PacTrack/PacTrackApp.swift`:

```swift
import AppKit
import PacEngine
import PacKit
import SwiftUI

private struct EditorKey: FocusedValueKey {
    typealias Value = Editor
}

extension FocusedValues {
    var editor: Editor? {
        get { self[EditorKey.self] }
        set { self[EditorKey.self] = newValue }
    }
}

struct PacTrackApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: PacDocument()) { file in
            MainView(document: file.$document)
        }
        .commands { EditCommands() }
    }
}

struct MainView: View {
    @Binding var document: PacDocument
    @State private var editor = Editor(client: Simulation())

    var body: some View {
        MainContent(editor: editor)
            .frame(minWidth: 1000, minHeight: 640)
            .toolbar { SimulationToolbar(editor: editor) }
            .focusedSceneValue(\.editor, editor)
            .preferredColorScheme(.dark)
            .task {
                await editor.load(document.topology)
                editor.onChange = { document.topology = $0 }
            }
            .task { await editor.runClock() }
    }
}

struct SimulationToolbar: ToolbarContent {
    @Bindable var editor: Editor

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await editor.undo() } } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                .disabled(!editor.canUndo)
            Button { Task { await editor.redo() } } label: { Label("Ripeti", systemImage: "arrow.uturn.forward") }
                .disabled(!editor.canRedo)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let running = editor.snapshot.running
            Button { Task { await editor.run(.setRunning(!running)) } } label: {
                Label(running ? "Pausa" : "Avvia", systemImage: running ? "pause.fill" : "play.fill")
            }
            Picker("Velocità", selection: Binding(get: { editor.snapshot.speed }, set: { v in Task { await editor.run(.setSpeed(v)) } })) {
                ForEach(SPEEDS, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .frame(width: 90)
            Text(String(format: "t = %.3f s", Double(editor.snapshot.timeNs) / 1e9))
                .font(Theme.mono)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 110, alignment: .trailing)
        }
    }
}

/// Undo/redo for the network; inside a text field the same shortcut edits the text instead.
struct EditCommands: Commands {
    @FocusedValue(\.editor) private var editor

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Annulla") {
                if typing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { Task { await editor?.undo() } }
            }
            .keyboardShortcut("z")
            Button("Ripeti") {
                if typing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { Task { await editor?.redo() } }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
```

`Sources/PacTrack/SelfTest.swift`:

```swift
import AppKit
import PacEngine
import PacKit
import SwiftUI

/// `PacTrack --selftest out.png`: drives the real Editor + Simulation, renders the window offscreen, exits 0/1.
@MainActor
enum SelfTest {
    static func run(output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let failures = await scenario(output: output)
            print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FAIL: " + failures.joined(separator: "; "))
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        for _ in 0..<5 { await editor.tick(wallMs: 100) }
        if editor.snapshot.timeNs != 500_000_000 { failures.append("clock at \(editor.snapshot.timeNs) ns, expected 500 ms") }
        if !render(editor, to: output) { failures.append("could not write \(output)") }
        return failures
    }

    static func render(_ editor: Editor, to path: String) -> Bool {
        let size = NSSize(width: 1400, height: 860)
        let host = NSHostingView(rootView: MainContent(editor: editor).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let SwiftUI finish layout
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
```

`Sources/PacTrack/main.swift`:

```swift
import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--selftest"), i + 1 < arguments.count {
    MainActor.assumeIsolated { SelfTest.run(output: arguments[i + 1]) }
} else {
    PacTrackApp.main()
}
```

Append to `.gitignore`:

```
# App bundle & selftest output
build/
```

- [ ] **Step 4: Run the selftest, the bundle and the unit tests**

Run: `scripts/selftest.sh build/selftest.png && scripts/bundle.sh && scripts/test.sh 2>&1 | tail -1`
Expected: `SELFTEST OK`; `build/PacTrack.app`; 104 tests passed. Open `build/selftest.png` (Read tool): dark window with the empty layout (palette, canvas, inspector, output areas).

Then launch the bundle for 4 s to prove it starts: `(build/PacTrack.app/Contents/MacOS/PacTrack > build/run.log 2>&1 &); sleep 4; pgrep -f PacTrack.app >/dev/null && echo RUNNING; pkill -f PacTrack.app`
Expected: `RUNNING`, empty `build/run.log`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore Resources scripts Sources/PacTrack
git commit -m "feat(app): add SwiftUI document app shell, toolbar, edit menu, bundle and selftest"
```

---

### Task 5: Palette, canvas and device nodes

**Files:**
- Create: `Sources/PacTrack/PaletteView.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/DeviceNodeView.swift`
- Modify: `Sources/PacTrack/MainContent.swift`, `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: `Editor` actions, `snap`, `firstIp`, `DeviceKind.label/symbol`
- Produces: `CanvasView(editor:)` (named coordinate space `"canvas"`, `nodeSize` 104×46), `DeviceNodeView`, `PaletteView`; accessibility ids `palette-<kind>`, `node-<name>`, `handle-<name>`, `link-<ifaceA>-<ifaceB>`; selftest scenario builds SW1 + PC1 + PC2 and two cables

- [ ] **Step 1: Extend the selftest scenario (failing)**

In `Sources/PacTrack/SelfTest.swift` replace the body of `scenario(output:)` with:

```swift
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        for _ in 0..<5 { await editor.tick(wallMs: 100) }
        if editor.snapshot.timeNs != 500_000_000 { failures.append("clock at \(editor.snapshot.timeNs) ns, expected 500 ms") }

        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.pc, at: Pos(x: 380, y: 340))
        await editor.addDevice(.pc, at: Pos(x: 740, y: 340))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("PC1"))
        await editor.connect(id("SW1"), id("PC2"))
        if editor.snapshot.links.count != 2 { failures.append("expected 2 cables, got \(editor.snapshot.links.count)") }
        if !render(editor, to: output) { failures.append("could not write \(output)") }
        return failures
```

Run: `scripts/selftest.sh build/selftest.png`, then Read `build/selftest.png`.
Expected: `SELFTEST OK` (the editor already works) but the picture is RED for this task: the canvas area is empty — no nodes or cables are drawn yet.

- [ ] **Step 2: Implement palette, canvas and node**

`Sources/PacTrack/PaletteView.swift`:

```swift
import PacEngine
import PacKit
import SwiftUI

struct PaletteView: View {
    private let groups: [(String, [DeviceKind])] = [("Rete", [.router, .switch, .hub]), ("Host", [.pc, .laptop, .server])]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.0) { title, kinds in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
                    ForEach(kinds, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .draggable(kind.rawValue)
                            .accessibilityIdentifier("palette-\(kind.rawValue)")
                    }
                }
            }
            Spacer()
            Text("Trascina un dispositivo sul canvas. Collega due dispositivi trascinando dal pallino in basso.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.panel)
    }
}
```

`Sources/PacTrack/DeviceNodeView.swift`:

```swift
import PacEngine
import PacKit
import SwiftUI

struct Wire {
    let from: String
    var to: CGPoint
}

struct DeviceNodeView: View {
    let node: NodeView
    @Bindable var editor: Editor
    let zoom: CGFloat
    let center: CGPoint
    let nodeAt: (CGPoint) -> String?
    @Binding var wire: Wire?
    @State private var dragStart: Pos?

    var body: some View {
        let selected = editor.selection == .node(node.id)
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: node.kind.symbol).font(.system(size: 11))
                Text(node.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.fgStrong)
                Circle().fill(node.ifaces.contains(where: \.linked) ? Theme.ok : Theme.muted).frame(width: 6, height: 6)
            }
            if let ip = firstIp(node) {
                Text(ip).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: CanvasView.nodeSize.width, height: CanvasView.nodeSize.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : Theme.borderStrong, lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .bottom) { handle }
        .scaleEffect(zoom)
        .position(center)
        .gesture(drag)
        .onTapGesture { editor.select(.node(node.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("node-\(node.name)")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = editor.positions[node.id] ?? Pos(x: 0, y: 0)
                    editor.moveStart()
                    editor.select(.node(node.id))
                }
                let start = dragStart!
                editor.setPosition(node.id, snap(Pos(x: start.x + value.translation.width / zoom, y: start.y + value.translation.height / zoom)))
            }
            .onEnded { _ in
                dragStart = nil
                editor.moveEnd()
            }
    }

    private var handle: some View {
        Circle()
            .fill(Theme.muted)
            .frame(width: 9, height: 9)
            .offset(y: 4.5)
            .contentShape(Circle().inset(by: -4))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasView.space))
                    .onChanged { wire = Wire(from: node.id, to: $0.location) }
                    .onEnded { value in
                        wire = nil
                        if let target = nodeAt(value.location), target != node.id {
                            Task { await editor.connect(node.id, target) }
                        }
                    }
            )
            .accessibilityIdentifier("handle-\(node.name)")
    }
}
```

`Sources/PacTrack/CanvasView.swift`:

```swift
import PacEngine
import PacKit
import SwiftUI

struct CanvasView: View {
    static let space = "canvas"
    static let nodeSize = CGSize(width: 104, height: 46)
    private static let grid: CGFloat = 14

    @Bindable var editor: Editor
    @State private var offset = CGSize.zero
    @State private var zoom: CGFloat = 1
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var wire: Wire?
    @State private var hover = CGPoint.zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                ForEach(editor.snapshot.links) { link in cable(link) }
                ForEach(editor.snapshot.nodes) { node in
                    DeviceNodeView(node: node, editor: editor, zoom: zoom, center: center(node.id), nodeAt: nodeAt, wire: $wire)
                }
                if let wire {
                    Path { p in
                        p.move(to: center(wire.from))
                        p.addLine(to: wire.to)
                    }
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
            .clipped()
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case .active(let p) = phase { hover = p }
            }
            .dropDestination(for: String.self) { items, location in
                guard let kind = items.first.flatMap(DeviceKind.init(rawValue:)) else { return false }
                Task { await editor.addDevice(kind, at: snap(toWorld(location))) }
                return true
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? zoom
                        zoomStart = start
                        zoom = min(max(start * value.magnification, 0.3), 3)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            .contextMenu { paneMenu(size: geo.size) }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { Task { await editor.deleteSelection() } }
            .onKeyPress(.space) {
                Task { await editor.run(.setRunning(!editor.snapshot.running)) }
                return .handled
            }
        }
    }

    // MARK: geometry

    private func toScreen(_ p: Pos) -> CGPoint {
        CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height)
    }

    private func toWorld(_ p: CGPoint) -> Pos {
        Pos(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom)
    }

    private func center(_ id: String) -> CGPoint {
        toScreen(editor.positions[id] ?? Pos(x: 0, y: 0))
    }

    private func nodeAt(_ point: CGPoint) -> String? {
        let w = Self.nodeSize.width * zoom
        let h = Self.nodeSize.height * zoom
        return editor.snapshot.nodes.last { node in
            let c = center(node.id)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h).contains(point)
        }?.id
    }

    private func fit(_ size: CGSize) {
        let points = editor.snapshot.nodes.compactMap { editor.positions[$0.id] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        zoom = min(max(min(size.width / (maxX - minX + 240), size.height / (maxY - minY + 160)), 0.3), 1.5)
        offset = CGSize(width: size.width / 2 - (minX + maxX) / 2 * zoom, height: size.height / 2 - (minY + maxY) / 2 * zoom)
    }

    // MARK: layers

    private var background: some View {
        Canvas { ctx, size in
            let step = Self.grid * zoom
            guard step >= 6 else { return }
            var x0 = offset.width.truncatingRemainder(dividingBy: step)
            if x0 < 0 { x0 += step }
            var y0 = offset.height.truncatingRemainder(dividingBy: step)
            if y0 < 0 { y0 += step }
            for x in stride(from: x0, through: size.width, by: step) {
                for y in stride(from: y0, through: size.height, by: step) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(Theme.border))
                }
            }
        }
        .background(Theme.bg)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let start = panStart ?? offset
                    panStart = start
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in panStart = nil }
        )
        .onTapGesture { editor.select(nil) }
    }

    private func cable(_ link: LinkView) -> some View {
        let a = center(link.a.node)
        let b = center(link.b.node)
        let selected = editor.selection == .link(link.id)
        let line = Path { p in
            p.move(to: a)
            p.addLine(to: b)
        }
        return ZStack {
            line.stroke(selected ? Theme.accent : Theme.muted, lineWidth: selected ? 2.5 : 1.5)
            Text("\(link.a.iface) ↔ \(link.b.iface)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 3)
                .background(Theme.bg)
                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        .contentShape(line.strokedPath(StrokeStyle(lineWidth: 12)))
        .onTapGesture { editor.select(.link(link.id)) }
        .accessibilityIdentifier("link-\(link.a.iface)-\(link.b.iface)")
    }

    @ViewBuilder
    private func paneMenu(size: CGSize) -> some View {
        Menu("Aggiungi dispositivo") {
            ForEach(DeviceKind.allCases, id: \.self) { kind in
                Button { Task { await editor.addDevice(kind, at: snap(toWorld(hover))) } } label: { Label(kind.label, systemImage: kind.symbol) }
            }
        }
        Button("Adatta alla vista") { fit(size) }
    }
}
```

Replace `Sources/PacTrack/MainContent.swift` with:

```swift
import PacKit
import SwiftUI

/// Window content without the toolbar (the selftest renders exactly this).
struct MainContent: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            PaletteView().frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                CanvasView(editor: editor)
                Divider()
                Theme.panel.frame(height: 170)
            }
            Divider()
            Theme.panel.frame(width: 290)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
```

- [ ] **Step 3: Run the selftest and look at the picture**

Run: `scripts/selftest.sh build/selftest.png && scripts/test.sh 2>&1 | tail -1`
Expected: `SELFTEST OK`; 104 tests passed. Read `build/selftest.png`: SW1 above PC1 and PC2, two cables labelled `Gi0/1 ↔ eth0` / `Gi0/2 ↔ eth0`, green LEDs, dotted grid, palette on the left.

- [ ] **Step 4: Commit**

```bash
git add Sources/PacTrack
git commit -m "feat(app): add palette, custom canvas with pan/zoom, nodes and cables"
```

---

### Task 6: Inspector and output panel

**Files:**
- Create: `Sources/PacTrack/Controls.swift`, `Sources/PacTrack/InspectorView.swift`, `Sources/PacTrack/OutputPanel.swift`
- Modify: `Sources/PacTrack/MainContent.swift`, `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: `Editor.edit/run/remove`, `gatewayOf`, `DeviceKind.hasIp`
- Produces: `CommitField`, `ErrorLine`, `TableSection`; `InspectorView(editor:)` with tabs Interfacce/Routing/Tabelle/App (IP nodes) or Porte/Tabelle (switch) or Porte (hub); `OutputPanel(editor:)`; selftest scenario adds IPs, pings and checks the output

- [ ] **Step 1: Extend the selftest scenario (failing)**

In `Sources/PacTrack/SelfTest.swift`, in `scenario(output:)`, insert before the `render` call:

```swift
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: id("PC2"), iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.2"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") { failures.append("ping output: \(lines)") }
        editor.select(.node(id("PC1")))
```

Run: `scripts/selftest.sh build/selftest.png`, then Read `build/selftest.png`.
Expected: `SELFTEST OK` (the ping runs in the editor) but the picture is RED for this task: inspector and output panel are empty grey areas.

- [ ] **Step 2: Implement controls, inspector and output**

`Sources/PacTrack/Controls.swift`:

```swift
import PacKit
import SwiftUI

struct ErrorLine: View {
    let editor: Editor
    let key: String

    var body: some View {
        if let error = editor.error, error.key == key {
            Text(error.message).font(Theme.small).foregroundStyle(Theme.err).accessibilityIdentifier("error-\(key)")
        }
    }
}

/// Text field that commits on Return or focus loss and reverts on Escape; shows the error tagged `errorKey`.
struct CommitField: View {
    let label: String
    let value: String
    var placeholder = ""
    let errorKey: String
    let editor: Editor
    let commit: (String) async -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.small).foregroundStyle(Theme.muted)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono)
                .focused($focused)
                .onAppear { draft = value }
                .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
                .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
                .onSubmit(submit)
                .onExitCommand {
                    draft = value
                    focused = false
                }
                .accessibilityIdentifier("field-\(errorKey)")
            ErrorLine(editor: editor, key: errorKey)
        }
    }

    private func submit() {
        guard draft != value else { return }
        let text = draft
        Task { await commit(text) }
    }
}

struct TableSection: View {
    let title: String
    let head: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9)).foregroundStyle(Theme.muted)
            if rows.isEmpty {
                Text("vuota").font(Theme.mono).foregroundStyle(Theme.muted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow { ForEach(head, id: \.self) { Text($0).foregroundStyle(Theme.muted) } }
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow { ForEach(rows[i].indices, id: \.self) { j in Text(rows[i][j]) } }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            }
        }
    }
}
```

`Sources/PacTrack/InspectorView.swift`:

```swift
import PacEngine
import PacKit
import SwiftUI

struct InspectorView: View {
    @Bindable var editor: Editor

    var body: some View {
        ScrollView {
            switch editor.selection {
            case .node(let id):
                if let node = editor.snapshot.nodes.first(where: { $0.id == id }) {
                    NodeInspector(node: node, editor: editor).id(node.id)
                }
            case .link(let id):
                if let link = editor.snapshot.links.first(where: { $0.id == id }) {
                    LinkInspector(link: link, editor: editor)
                }
            case nil:
                Text("Seleziona un dispositivo o un collegamento.").foregroundStyle(Theme.muted).padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .accessibilityIdentifier("inspector")
    }
}

private enum Tab: String, CaseIterable {
    case interfaces = "Interfacce", ports = "Porte", routing = "Routing", tables = "Tabelle", app = "App"
}

private struct NodeInspector: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var tab: Tab

    init(node: NodeView, editor: Editor) {
        self.node = node
        self.editor = editor
        _tab = State(initialValue: node.kind.hasIp ? .interfaces : .ports)
    }

    private var tabs: [Tab] {
        node.kind.hasIp ? [.interfaces, .routing, .tables, .app] : node.kind == .switch ? [.ports, .tables] : [.ports]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: node.kind.symbol).font(.system(size: 16))
                CommitField(label: node.kind.label, value: node.name, errorKey: "name:\(node.id)", editor: editor) {
                    await editor.edit(.rename(id: node.id, name: $0), key: "name:\(node.id)")
                }
            }
            Picker("", selection: $tab) { ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
            switch tab {
            case .interfaces: interfaces
            case .ports: ports
            case .routing: RoutingTab(node: node, editor: editor)
            case .tables: tables
            case .app: AppTab(node: node, editor: editor)
            }
        }
        .padding(12)
    }

    private var interfaces: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(node.ifaces, id: \.name) { iface in
                let key = "ip:\(node.id):\(iface.name)"
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(iface.name).foregroundStyle(Theme.fgStrong)
                        Spacer()
                        Text(iface.linked ? "● collegata" : "○ libera").foregroundStyle(iface.linked ? Theme.ok : Theme.muted)
                    }
                    .font(.system(size: 11))
                    CommitField(label: "Indirizzo IPv4 / prefisso", value: iface.cidr ?? "", placeholder: "192.168.1.10/24", errorKey: key, editor: editor) { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        await editor.edit(.setIp(node: node.id, iface: iface.name, cidr: trimmed.isEmpty ? nil : trimmed), key: key)
                    }
                    Text("MAC \(iface.mac)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(node.ifaces, id: \.name) { iface in
                HStack {
                    Text(iface.name)
                    Spacer()
                    Text(iface.linked ? "● collegata" : "○ libera").foregroundStyle(iface.linked ? Theme.ok : Theme.muted)
                }
                .font(Theme.mono)
            }
        }
    }

    private var tables: some View {
        VStack(alignment: .leading, spacing: 14) {
            if node.kind == .switch {
                TableSection(title: "Tabella MAC", head: ["MAC", "Porta", "Età"], rows: node.mac.map { [$0.mac, $0.iface, "\($0.ageS)s"] })
            } else {
                TableSection(title: "Tabella di routing", head: ["Destinazione", "Next hop", "Int."],
                             rows: node.routes.map { [$0.dest, $0.nextHop ?? "connessa", $0.iface] })
                TableSection(title: "Cache ARP", head: ["IP", "MAC", "Int.", "TTL"], rows: node.arp.map { [$0.ip, $0.mac, $0.iface, "\($0.ttlS)s"] })
            }
        }
    }
}

private struct RoutingTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var cidr = ""
    @State private var via = ""

    var body: some View {
        let gateway = gatewayOf(node) ?? ""
        let gwKey = "gw:\(node.id)"
        let routeKey = "route:\(node.id)"
        VStack(alignment: .leading, spacing: 14) {
            CommitField(label: "Gateway predefinito", value: gateway, placeholder: "192.168.1.1", errorKey: gwKey, editor: editor) { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    await editor.edit(.addRoute(node: node.id, cidr: "0.0.0.0/0", nextHop: trimmed), key: gwKey)
                } else if !gateway.isEmpty {
                    await editor.edit(.removeRoute(node: node.id, cidr: "0.0.0.0/0"), key: gwKey)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ROUTE STATICHE").font(.system(size: 9)).foregroundStyle(Theme.muted)
                let statics = node.routes.filter { $0.isStatic && $0.dest != "0.0.0.0/0" }
                if statics.isEmpty { Text("nessuna").font(Theme.small).foregroundStyle(Theme.muted) }
                ForEach(statics, id: \.dest) { route in
                    HStack {
                        Text("\(route.dest) via \(route.nextHop ?? "-")").font(Theme.mono)
                        Spacer()
                        Button { Task { await editor.edit(.removeRoute(node: node.id, cidr: route.dest), key: routeKey) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Rimuovi route")
                    }
                }
                HStack {
                    TextField("10.0.2.0/24", text: $cidr).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("next hop", text: $via).textFieldStyle(.roundedBorder).font(Theme.mono)
                    Button("+") {
                        Task {
                            if await editor.edit(.addRoute(node: node.id, cidr: cidr, nextHop: via), key: routeKey) {
                                cidr = ""
                                via = ""
                            }
                        }
                    }
                }
                ErrorLine(editor: editor, key: routeKey)
            }
        }
    }
}

private struct AppTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var target = ""

    var body: some View {
        let key = "app:\(node.id)"
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinazione").font(Theme.small).foregroundStyle(Theme.muted)
            TextField("10.0.0.2", text: $target).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("app-target")
            HStack {
                Button("Ping") { Task { await editor.run(.ping(node: node.id, target: target), key: key) } }
                Button("Traceroute") { Task { await editor.run(.traceroute(node: node.id, target: target), key: key) } }
            }
            ErrorLine(editor: editor, key: key)
            Text("L'output compare nel pannello in basso.").font(Theme.small).foregroundStyle(Theme.muted)
        }
    }
}

private struct LinkInspector: View {
    let link: LinkView
    @Bindable var editor: Editor

    var body: some View {
        let name = { (id: String) in editor.snapshot.nodes.first { $0.id == id }?.name ?? "?" }
        VStack(alignment: .leading, spacing: 10) {
            Text("Collegamento Ethernet").foregroundStyle(Theme.fgStrong)
            Text("\(name(link.a.node)) \(link.a.iface) ↔ \(name(link.b.node)) \(link.b.iface)").font(Theme.mono)
            Text("1 Gb/s · 500 ns (modificabile nella prossima versione)").font(Theme.small).foregroundStyle(Theme.muted)
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
        .padding(12)
    }
}
```

`Sources/PacTrack/OutputPanel.swift`:

```swift
import PacKit
import SwiftUI

struct OutputPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        let apps = editor.snapshot.apps
        let name = { (id: String) in editor.snapshot.nodes.first { $0.id == id }?.name ?? "(rimosso)" }
        VStack(alignment: .leading, spacing: 0) {
            Text("Output app").font(.system(size: 11)).foregroundStyle(Theme.fgStrong).padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if apps.isEmpty {
                            Text("Nessuna applicazione avviata: usa la scheda App dell'ispettore o il menu contestuale di un dispositivo.")
                                .foregroundStyle(Theme.muted)
                        }
                        ForEach(apps) { app in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(name(app.node))$ \(app.title)\(app.done ? "" : " …")").foregroundStyle(Theme.accent)
                                ForEach(app.lines.indices, id: \.self) { Text(app.lines[$0]) }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: apps.reduce(0) { $0 + $1.lines.count }) { proxy.scrollTo("end") }
            }
        }
        .background(Theme.panel)
        .accessibilityIdentifier("output")
    }
}
```

Replace `Sources/PacTrack/MainContent.swift` with:

```swift
import PacKit
import SwiftUI

/// Window content without the toolbar (the selftest renders exactly this).
struct MainContent: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            PaletteView().frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                CanvasView(editor: editor)
                Divider()
                OutputPanel(editor: editor).frame(height: 170)
            }
            Divider()
            InspectorView(editor: editor).frame(width: 290)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
```

- [ ] **Step 3: Run the selftest and look at the picture**

Run: `scripts/selftest.sh build/selftest.png && scripts/test.sh 2>&1 | tail -1`
Expected: `SELFTEST OK`; 104 tests passed. Read `build/selftest.png`: inspector shows PC1 with the `Interfacce` tab and `10.0.0.1/24`; output panel shows `PC1$ ping 10.0.0.2` and four `64 bytes from 10.0.0.2` lines plus statistics.

- [ ] **Step 4: Commit**

```bash
git add Sources/PacTrack
git commit -m "feat(app): add inspector tabs and app output panel"
```

---

### Task 7: Node and cable context menus, manual checklist

**Files:**
- Modify: `Sources/PacTrack/DeviceNodeView.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/SelfTest.swift`
- Create: `docs/manual-checks/m2a.md`

**Interfaces:**
- Consumes: `Editor.run/remove/select`, `firstIp`, `DeviceKind.hasIp`
- Produces: node menu (*Apri ispettore*, *Ping verso ▸*, *Traceroute verso ▸*, *Elimina*), cable menu (*Scollega*); `NodeMenu.targets(for:in:)` used by the selftest

- [ ] **Step 1: Extend the selftest (failing)**

In `Sources/PacTrack/SelfTest.swift`, in `scenario(output:)`, insert before the `render` call:

```swift
        let targets = NodeMenu.targets(for: id("PC1"), in: editor.snapshot.nodes).map(\.name)
        if targets != ["PC2"] { failures.append("ping menu targets \(targets), expected [PC2]") }
```

Run: `scripts/selftest.sh build/selftest.png`
Expected: build FAIL — `cannot find 'NodeMenu' in scope`.

- [ ] **Step 2: Implement the menus**

Append to `Sources/PacTrack/DeviceNodeView.swift`:

```swift
struct NodeMenu: View {
    let node: NodeView
    let editor: Editor

    /// Other devices that have an address to aim an app at.
    static func targets(for id: String, in nodes: [NodeView]) -> [NodeView] {
        nodes.filter { $0.id != id && firstIp($0) != nil }
    }

    var body: some View {
        Button("Apri ispettore") { editor.select(.node(node.id)) }
        if node.kind.hasIp {
            let targets = Self.targets(for: node.id, in: editor.snapshot.nodes)
            Menu("Ping verso") {
                ForEach(targets) { t in
                    Button("\(t.name)  \(firstIp(t) ?? "")") { Task { await editor.run(.ping(node: node.id, target: firstIp(t) ?? ""), key: "app:\(node.id)") } }
                }
            }
            .disabled(targets.isEmpty)
            Menu("Traceroute verso") {
                ForEach(targets) { t in
                    Button("\(t.name)  \(firstIp(t) ?? "")") { Task { await editor.run(.traceroute(node: node.id, target: firstIp(t) ?? ""), key: "app:\(node.id)") } }
                }
            }
            .disabled(targets.isEmpty)
        }
        Divider()
        Button("Elimina", role: .destructive) { Task { await editor.remove(nodes: [node.id], links: []) } }
    }
}
```

In `DeviceNodeView.body`, add after `.onTapGesture { editor.select(.node(node.id)) }`:

```swift
        .contextMenu { NodeMenu(node: node, editor: editor) }
```

In `CanvasView.cable(_:)`, add after `.onTapGesture { editor.select(.link(link.id)) }`:

```swift
        .contextMenu {
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
```

- [ ] **Step 3: Write the manual checklist**

`docs/manual-checks/m2a.md`:

```markdown
# M2a — manual checks (no Xcode UI tests yet)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`

- [ ] File ▸ Nuovo opens an empty window; the clock in the toolbar advances.
- [ ] Drag *PC* and *Switch* from the palette onto the canvas: PC1 and SW1 appear where dropped.
- [ ] Drag from PC1's bottom dot onto SW1: a cable `eth0 ↔ Gi0/1` appears, LEDs turn green.
- [ ] Drag a node: it moves on the 14 pt grid; Cmd+Z puts it back.
- [ ] Pinch to zoom, drag the empty background to pan; right-click ▸ *Adatta alla vista* frames all devices.
- [ ] Right-click empty canvas ▸ *Aggiungi dispositivo* ▸ *Router*: R1 appears under the pointer.
- [ ] Select PC1 ▸ *Interfacce*: type `10.0.0.1/24` + Return; the node shows the IP. Type `10.0.0.999/24`: red error under the field, IP unchanged.
- [ ] While typing in a field, Cmd+Z undoes the typing, not the network.
- [ ] Second PC with `10.0.0.2/24` on the switch; right-click PC1 ▸ *Ping verso* ▸ PC2: output shows four replies.
- [ ] *Tabelle* on PC1 shows the ARP entry; on SW1 the MAC table.
- [ ] Select SW1 and press Delete: switch and cables disappear; Cmd+Z brings all back; Cmd+Shift+Z deletes again.
- [ ] Right-click a cable ▸ *Scollega*.
- [ ] Space pauses/resumes the clock; the speed menu changes it.
- [ ] Cmd+S saves `rete.ptk`; close and reopen it from Finder: same devices, positions, IPs and routes.
- [ ] Open a text file renamed to `.ptk`: macOS shows an error, nothing else opens.
```

- [ ] **Step 4: Run everything**

Run: `scripts/selftest.sh build/selftest.png && scripts/test.sh 2>&1 | tail -1 && scripts/bundle.sh`
Expected: `SELFTEST OK`, 104 tests passed, `build/PacTrack.app` built. Launch it for 4 s as in Task 4: `RUNNING`, empty log.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacTrack docs/manual-checks
git commit -m "feat(app): add node and cable context menus and the manual checklist"
```

---

## Done criteria for M2a

- `scripts/test.sh` green (104), `scripts/selftest.sh` prints `SELFTEST OK` and the PNG shows the topology, inspector and ping output, `scripts/bundle.sh` produces an app that launches cleanly.
- The manual checklist is ready for the user.
- Next: M2b plan (Simulation mode + step, event list + PDU inspector, packet animation, link properties, power, copy/paste, palette search, resizable output panel, loop warning).
