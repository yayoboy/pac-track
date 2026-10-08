# M2b — Visual simulation: time modes, events, PDU inspector, animation, link and power editing (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch the network work: a Realtime/Simulation switch with step and slow play, a filterable event list with a header-by-header PDU inspector, protocol-coloured PDUs moving along cables, editable link properties with fault simulation, device power, copy/paste/duplicate, palette search and an L2 loop warning — plus the M2a deferred fixes.

**Architecture:** `PacEngine` gains validated link updates, power reset, an L2 loop detector, indexed log reads and an event budget per clock tick; the `Runtime` façade adds the commands (`setMode`, `step`, `setPower`, `updateLink`, `setLinkUp`), cheap snapshot fields (`mode`, `epoch`, `eventCount`, `warnings`) and two pull queries (`events(from:)`, `pdu(_:)`) so a 100 000-entry log never rides along with a 50 ms snapshot. `PacKit`'s `Editor` pulls only events newer than its cursor, derives on-screen "flights" (tx → rx) for the animation, and implements step, copy/paste/duplicate and link-field parsing. `PacTrack` adds the toolbar mode switch, a resizable bottom panel (Eventi / Output app) with the PDU inspector, the animation layer, link/power UI, palette search and the gesture fixes.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM — Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2: §5.2, §5.4 switch row, §6 "Modalità di tempo", §7.1–7.4, §8, §9 — milestone M2b). Conventions: `docs/superpowers/plans/2026-10-07-m2a-swiftui-app.md`.

## Global Constraints

- Run every `swift`/`scripts/*.sh` command **outside the sandbox**; unit tests only via `scripts/test.sh` (bare `swift test` runs zero tests with CLT). End-to-end: `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`.
- The UI never holds engine objects — only `Snapshot`/`EventView`/`PduLayer` values and string ids.
- Never store `SimTimer`s or closures that capture their owner; cancel by state checks. Removed nodes stay alive until the Sim is replaced.
- Never iterate a `Dictionary` on the simulation path or for anything shown in order.
- Every network change goes through `Editor.edit` (one undo step); clock/apps/step through `Editor.run`. The editor accepts only snapshots with a newer `version`.
- `.ptk` round trip keeps link options, link state and power; files written by M2a (no such keys) still open — `Topology.version` stays `1` (new keys are optional on read).
- Snapshots stay cheap: events are pulled by sequence number (`events(from:)`), at most 5 000 per pull; PDUs are decoded only on demand (`pdu(_:)`).
- User-facing copy Italian; engine error messages stay English like M2a's; code, comments, tests, commits English. Colors only from `Theme` (ARP `#f0a732`, ICMP `#e5507a`, UDP `#2fbfc4`).
- Ponytail: no APIs for later milestones (no DHCP/DNS/TCP colours in code, no Metriche tab, no "Rinnova DHCP"); deliberate shortcuts carry a `ponytail:` comment.
- Commit trailer:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FbFogmKCbqCctTUt5TujDV
  ```

## Review Focus

1. **A broadcast storm in an L2 loop** → the app must stay responsive (bounded work per tick, bounded event pulls) and show the loop warning. Pinned: `Scheduler` budget test (Task 1), `reportsAnL2LoopAsAWarningAndBoundsTheWorkPerTick` (Task 2), loop scenario in the selftest (Task 4).
2. **Undo/reload while events or flights are on screen** → the list must not mix events of the old network with the new one (sequence numbers restart). Pinned: `Snapshot.epoch` + `pullsOnlyNewEventsAndClearsThemWhenTheNetworkIsReloaded` (Task 3).
3. **Absurd link values typed by a person** (`abc`, `nan`, `inf`, `1e300`, `150` %, negative) → field error, network unchanged, no crash on `Int` conversion. Pinned: `LinkField` tests (Task 3) + engine validation tests (Task 1).
4. **Opening an M2a `.ptk`** (no `options`, `up`, `powered` keys) → opens with defaults. Pinned: `decodesFilesWithoutLinkOptionsOrPower` (Task 2).
5. **Stepping with nothing scheduled / timers that log nothing** → `step` returns, never spins. Pinned: `stepWithAnEmptyQueueDoesNothing` (Task 2).

## File Structure

```
Sources/PacEngine/Link.swift                 public LinkOptions (Codable), validateLinkOptions, Link.update
Sources/PacEngine/Node.swift                 Node.reset() (power cycle)
Sources/PacEngine/L3/Arp.swift               Arp.reset()
Sources/PacEngine/L3/IpNode.swift            reset override
Sources/PacEngine/Devices/Switch.swift       reset override, loop note
Sources/PacEngine/Devices/Hub.swift          loop note
Sources/PacEngine/Sim.swift                  L2 loop detector, warnings, run budget
Sources/PacEngine/Scheduler.swift            runUntil(_:maxEvents:)
Sources/PacEngine/Events.swift               public EventKind, EventLog.since/event
Sources/PacEngine/Runtime/Protocol.swift     new commands, SimMode, Proto, EventView, PduLayer, WarningView, snapshot fields
Sources/PacEngine/Runtime/EventViews.swift   SimEvent -> EventView / [PduLayer]
Sources/PacEngine/Runtime/Runtime.swift      modes, step, power, link updates, stable versions, queries, load
Sources/PacKit/Simulation.swift              EngineClient.events/pdu
Sources/PacKit/EventHelpers.swift            formatSimTime, filterEvents, labels, flights
Sources/PacKit/Topology+Helpers.swift        LinkField, formatBandwidth, powered in makeTopology
Sources/PacKit/Editor.swift                  event sync, flights, step, PDU selection, copy/paste/duplicate, setLink, warnings
Sources/PacTrack/PacTrackApp.swift           MainView (one Editor), toolbar mode/step/time, pasteboard commands
Sources/PacTrack/MainContent.swift           VSplitView + bottom panel
Sources/PacTrack/BottomPanel.swift           tabs Eventi / Output app
Sources/PacTrack/EventsPanel.swift           filters, list, PDU inspector
Sources/PacTrack/OutputPanel.swift           no own title (tab provides it)
Sources/PacTrack/CanvasView.swift            flights layer, cable state/menu, paste, anchored zoom, scroll pan, menu point, `.` key
Sources/PacTrack/DeviceNodeView.swift        power look, node menu power/duplicate/copy
Sources/PacTrack/InspectorView.swift         link properties, power button
Sources/PacTrack/PaletteView.swift           search
Sources/PacTrack/Controls.swift              CommitField ends editing on Return, WarningBanner, "link:" field errors
Sources/PacTrack/Theme.swift                 warn + protocol colors
Sources/PacTrack/SelfTest.swift              M2b scenarios
Tests/PacEngineTests/{LinkTests,SchedulerTests,L2Tests,RuntimeTests}.swift
Tests/PacKitTests/{EditorTests,HelpersTests}.swift
docs/manual-checks/m2b.md
```

---

### Task 1: Engine — link updates, power reset, loop detector, log reads, tick budget

**Files:**
- Modify: `Sources/PacEngine/Link.swift`, `Sources/PacEngine/Node.swift`, `Sources/PacEngine/L3/Arp.swift`, `Sources/PacEngine/L3/IpNode.swift`, `Sources/PacEngine/Devices/Switch.swift`, `Sources/PacEngine/Devices/Hub.swift`, `Sources/PacEngine/Sim.swift`, `Sources/PacEngine/Scheduler.swift`, `Sources/PacEngine/Events.swift`
- Test: `Tests/PacEngineTests/LinkTests.swift`, `Tests/PacEngineTests/SchedulerTests.swift`, `Tests/PacEngineTests/L2Tests.swift`

**Interfaces:**
- Produces: `public struct LinkOptions: Codable, Equatable, Sendable` (public init with the old defaults); `func validateLinkOptions(_:) throws` (messages start with `Invalid link options: `); `Link.opts` is `private(set) var`; `Link.update(_ opts: LinkOptions) throws`; `Node.reset()` (no-op; IpNode clears ARP, Switch clears MAC table); `Arp.reset()`; `struct SimWarning { id: Int; node: String; time: Int }`; `Sim.warnings: [SimWarning]` (newest 20, ids from 1); `Sim.noteL2(_ frame:, at node: String)`; `Scheduler.runUntil(_ time: Int, maxEvents: Int = .max)`; `public enum EventKind: String`; `EventLog.since(_ seq: Int) -> [SimEvent]`; `EventLog.event(_ seq: Int) -> SimEvent?`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct EventLogTests` in `Tests/PacEngineTests/LinkTests.swift`:

```swift
    @Test func readsEventsBySequenceNumberAcrossTheRingWrap() {
        let log = EventLog(capacity: 3)
        for t in 0..<5 { log.push(SimEvent(time: t, kind: .tx, node: "A")) }
        #expect(log.since(0).map(\.seq) == [2, 3, 4])
        #expect(log.since(4).map(\.time) == [4])
        #expect(log.since(5).isEmpty)
        #expect(log.event(1) == nil)
        #expect(log.event(3)?.time == 3)
    }
```

Append inside `struct LinkTests`:

```swift
    @Test func updatesOptionsForLaterFramesAndValidatesThem() throws {
        let (sim, a, b, link) = try pair()
        try link.update(LinkOptions(bandwidthBps: 1e6, propDelayNs: 1 * MS))
        try a.sendRaw()
        sim.run(10 * MS)
        #expect(b.got.map(\.time) == [672_000 + 1 * MS]) // 84 wire bytes at 1 Mb/s + 1 ms
        expectError("loss rate") { try link.update(LinkOptions(lossRate: 2)) }
        expectError("propagation delay") { try link.update(LinkOptions(propDelayNs: 11 * S)) }
        expectError("bandwidth") { try link.update(LinkOptions(bandwidthBps: .infinity * 0)) }
        #expect(link.opts == LinkOptions(bandwidthBps: 1e6, propDelayNs: 1 * MS))
    }
```

Append inside `struct SchedulerTests` in `Tests/PacEngineTests/SchedulerTests.swift`:

```swift
    @Test func runUntilStopsAtTheEventBudgetWithoutJumpingAhead() {
        let s = Scheduler()
        var fired = 0
        for t in 1...10 { s.at(t) { fired += 1 } }
        s.runUntil(100, maxEvents: 4)
        #expect(fired == 4 && s.now == 4)
        s.runUntil(100)
        #expect(fired == 10 && s.now == 100)
    }
```

Append inside `struct L2Tests` in `Tests/PacEngineTests/L2Tests.swift`:

```swift
    @Test func warnsOncePerSwitchAboutALayer2Loop() throws {
        let sim = Sim(logCapacity: 1000)
        let sw1 = Switch(sim: sim, id: "SW1")
        let sw2 = Switch(sim: sim, id: "SW2")
        _ = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
        _ = try Link(sim: sim, try sw1.iface("Gi0/2"), try sw2.iface("Gi0/2"))
        let a = Probe(sim: sim, id: "A")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
        try a.sendRaw()
        sim.run(10 * MS)
        #expect(Set(sim.warnings.map(\.node)) == ["SW1", "SW2"])
        #expect(sim.warnings.count == 2)
        #expect(sim.warnings.map(\.id).sorted() == [1, 2])
    }

    @Test func aTreeNeverWarns() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B", "C"])
        try p[0].sendRaw()
        try p[1].sendRaw()
        sim.run(MS)
        #expect(sim.warnings.isEmpty)
    }

    @Test func powerResetForgetsTheMacTable() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B"])
        try p[0].sendRaw()
        sim.run(MS)
        sw.reset()
        #expect(sw.macTable().isEmpty)
    }
```

Append inside `struct IpTests` in `Tests/PacEngineTests/IpTests.swift` (`lan()` is the existing helper in `TestUtils.swift`):

```swift
    @Test func powerResetForgetsTheArpCache() throws {
        let (sim, _, a, _) = try lan()
        a.sendUdp(try parseIp("10.0.0.2"), srcPort: 1, dstPort: 9, data: [])
        sim.run(10 * MS)
        #expect(a.arp.entries().count == 1)
        a.reset()
        #expect(a.arp.entries().isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh 2>&1 | grep -E "error:|passed|failed" | head`
Expected: compile errors — `since`, `event`, `update`, `runUntil(_:maxEvents:)`, `warnings`, `reset` do not exist.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Link.swift` — replace the `LinkOptions` struct and the options guard:

```swift
/// Defaults: 1 Gb/s copper, ~100 m.
public struct LinkOptions: Codable, Equatable, Sendable {
    public var bandwidthBps: Double
    public var propDelayNs: Int
    public var lossRate: Double
    public var queueLimit: Int

    public init(bandwidthBps: Double = 1e9, propDelayNs: Int = 500, lossRate: Double = 0, queueLimit: Int = 1000) {
        self.bandwidthBps = bandwidthBps
        self.propDelayNs = propDelayNs
        self.lossRate = lossRate
        self.queueLimit = queueLimit
    }
}

/// Upper bound keeps timer arithmetic far from overflow (a geostationary hop is ~0.25 s).
private let MAX_PROP_DELAY_NS = 10 * S

func validateLinkOptions(_ o: LinkOptions) throws {
    let problem: String? =
        !(o.bandwidthBps >= 1) ? "bandwidth must be at least 1 b/s"
        : !(0...MAX_PROP_DELAY_NS).contains(o.propDelayNs) ? "propagation delay must be between 0 and 10 s"
        : !(0...1).contains(o.lossRate) ? "loss rate must be between 0 and 100%"
        : o.queueLimit < 0 ? "queue limit cannot be negative"
        : nil
    if let problem { throw EngineError("Invalid link options: \(problem)") }
}
```

In `final class Link`: `let opts: LinkOptions` → `private(set) var opts: LinkOptions`; replace the `guard opts.bandwidthBps >= 1, … else { throw EngineError("Invalid link options: \(opts)") }` with `try validateLinkOptions(opts)`; add after `peer(_:)`:

```swift
    /// New options apply to frames that start transmitting from now on; queued frames keep waiting.
    func update(_ opts: LinkOptions) throws {
        try validateLinkOptions(opts)
        self.opts = opts
    }
```

`Sources/PacEngine/Node.swift` — in `class Node`, after `receive`:

```swift
    /// Power cycle: forgets everything learned at run time (configuration stays).
    func reset() {}
```

`Sources/PacEngine/L3/Arp.swift` — in `final class Arp`, after `entries()`:

```swift
    /// Empties the cache and abandons pending resolutions (their retry timers find nothing pending and stop).
    func reset() {
        cache = [:]
        pending = [:]
    }
```

`Sources/PacEngine/L3/IpNode.swift` — in `class IpNode`, after `onIcmp`:

```swift
    override func reset() {
        arp.reset()
    }
```

`Sources/PacEngine/Devices/Switch.swift` — add to `Switch`:

```swift
    override func reset() {
        table = [:]
    }
```

and make `receive` start with `sim.noteL2(frame, at: id)`. `Sources/PacEngine/Devices/Hub.swift`: same first line in `receive`.

`Sources/PacEngine/Sim.swift` — add above `final class Sim`:

```swift
/// A frame seen this many times by one L2 device within the window means a loop (a tree delivers it once).
let LOOP_REPEATS = 3
let LOOP_WINDOW_NS = 1 * S
/// A device that warned stays quiet this long.
let LOOP_QUIET_NS = 10 * S
private let LOOP_MEMORY = 64
private let MAX_WARNINGS = 20

struct SimWarning: Equatable, Sendable {
    let id: Int
    let node: String
    let time: Int
}
```

inside `Sim`:

```swift
    /// Newest L2 loop warnings, oldest first.
    private(set) var warnings: [SimWarning] = []
    private var warningCount = 0
    private var l2Seen: [String: [(frame: Int, time: Int)]] = [:]
    private var lastWarned: [String: Int] = [:]

    /// Hubs and switches report every frame they receive.
    // ponytail: last 64 frames per device, O(64) per frame; a hash of recent ids if storms get bigger
    func noteL2(_ frame: EthernetFrame, at node: String) {
        var recent = l2Seen[node, default: []]
        recent.append((frame.id, now))
        if recent.count > LOOP_MEMORY { recent.removeFirst(recent.count - LOOP_MEMORY) }
        l2Seen[node] = recent
        let repeats = recent.reduce(0) { $0 + ($1.frame == frame.id && now - $1.time <= LOOP_WINDOW_NS ? 1 : 0) }
        guard repeats >= LOOP_REPEATS, now - (lastWarned[node] ?? -LOOP_QUIET_NS) >= LOOP_QUIET_NS else { return }
        lastWarned[node] = now
        warningCount += 1
        warnings.append(SimWarning(id: warningCount, node: node, time: now))
        if warnings.count > MAX_WARNINGS { warnings.removeFirst() }
    }
```

`Sources/PacEngine/Scheduler.swift` — replace `runUntil`:

```swift
    /// Runs events up to `time`. With a budget, stops after `maxEvents` and leaves `now` at the last event run.
    func runUntil(_ time: Int, maxEvents: Int = .max) {
        var count = 0
        while count < maxEvents, let timer = peek(), timer.time <= time {
            step()
            count += 1
        }
        if count < maxEvents, time > now { now = time }
    }
```

`Sources/PacEngine/Events.swift` — `enum EventKind: Sendable` → `public enum EventKind: String, Sendable`; in `EventLog` add:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: all tests pass (106 + 7 new = 113).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine Tests/PacEngineTests
git commit -m "feat(engine): add link updates, power reset, L2 loop detector, indexed log reads and a tick budget"
```

---

### Task 2: Runtime — modes, step, power, link commands, stable versions, event and PDU queries

**Files:**
- Modify: `Sources/PacEngine/Runtime/Protocol.swift`, `Sources/PacEngine/Runtime/Runtime.swift`
- Create: `Sources/PacEngine/Runtime/EventViews.swift`
- Test: `Tests/PacEngineTests/RuntimeTests.swift`

**Interfaces:**
- Consumes: Task 1 (`LinkOptions`, `Link.update`, `Node.reset`, `Sim.warnings`, `runUntil(_:maxEvents:)`, `EventLog.since/event`, `EventKind`).
- Produces:
  - `public enum SimMode: String, Codable, Sendable { case realtime, simulation }`
  - `public enum Proto: String, CaseIterable, Sendable { case arp, icmp, udp }`
  - `Command` cases `.setMode(SimMode)`, `.step`, `.setPower(id: String, on: Bool)`, `.updateLink(id: String, options: LinkOptions)`, `.setLinkUp(id: String, up: Bool)` (keys `setMode`, `step`, `setPower`, `updateLink`, `setLinkUp`)
  - `public struct EventView: Equatable, Identifiable, Sendable { id: Int (log seq); timeNs: Int; kind: EventKind; node: String; iface: String?; proto: Proto; frameId: Int?; bytes: Int; info: String; reason: String? }` with a public memberwise-order init
  - `public struct PduField { name, value: String }`, `public struct PduLayer { title: String; bytes: Int; fields: [PduField] }`
  - `public struct WarningView: Equatable, Identifiable, Sendable { id: Int; node: String; timeNs: Int }`
  - `NodeView.powered: Bool`; `LinkView.options: LinkOptions`, `LinkView.up: Bool` (init defaults; decode defaults); `TopologyNode.powered: Bool` (init default `true`; decode default)
  - `Snapshot.mode: SimMode`, `.epoch: Int`, `.eventCount: Int`, `.warnings: [WarningView]`; `version` changes only when content changes
  - `Runtime.epoch: Int` (bumped by `load`), `Runtime.mode`, `Runtime.events(from seq: Int, limit: Int = 5000) -> [EventView]`, `Runtime.pdu(_ seq: Int) -> [PduLayer]?`

- [ ] **Step 1: Write the failing tests**

Add `import Foundation` at the top of `Tests/PacEngineTests/RuntimeTests.swift` and append inside `struct RuntimeTests`:

```swift
    @Test func simulationModeStopsTheClockAndStepsToTheNextLoggedEvent() throws {
        let rt = try lanRuntime()
        try rt.handle(.setMode(.simulation))
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        rt.advance(wallMs: 100)
        var s = rt.snapshot()
        #expect(s.mode == .simulation && !s.running && s.timeNs == 0 && s.eventCount == 0)
        try rt.handle(.step)
        s = rt.snapshot()
        #expect(s.eventCount == 1)
        #expect(rt.events(from: 0).map { "\($0.kind.rawValue) \($0.node) \($0.proto.rawValue)" } == ["tx a arp"])
        try rt.handle(.step) // the request reaches the switch, which floods it in the same instant
        #expect(rt.events(from: 1).map { "\($0.kind.rawValue) \($0.node)" } == ["rx s", "tx s"])
        #expect(rt.snapshot().timeNs == 1172)
        try rt.handle(.setMode(.realtime))
        #expect(rt.snapshot().running)
    }

    @Test func simulationPlayStepsTwicePerSecondOfWallTimeAtSpeedOne() throws {
        let played = try lanRuntime()
        let stepped = try lanRuntime()
        for rt in [played, stepped] {
            try rt.handle(.setMode(.simulation))
            try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        }
        try played.handle(.setRunning(true))
        runFor(played, wallMs: 1000)
        try stepped.handle(.step)
        try stepped.handle(.step)
        #expect(played.snapshot().eventCount == stepped.snapshot().eventCount)
        #expect(played.snapshot().timeNs == stepped.snapshot().timeNs)
    }

    @Test func stepWithAnEmptyQueueDoesNothing() throws {
        let rt = Runtime()
        try rt.handle(.setMode(.simulation))
        try rt.handle(.step)
        #expect(rt.snapshot().timeNs == 0 && rt.snapshot().eventCount == 0)
    }

    @Test func snapshotVersionChangesOnlyWhenTheContentDoes() throws {
        let rt = try lanRuntime()
        try rt.handle(.setRunning(false))
        let v = rt.snapshot().version
        rt.advance(wallMs: 50)
        #expect(rt.snapshot().version == v)
        try rt.handle(.rename(id: "a", name: "X"))
        #expect(rt.snapshot().version == v + 1)
    }

    @Test func listsEventsAndDecodesTheirPduHeaderByHeader() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 500)
        let events = rt.events(from: 0)
        #expect(events.map(\.id) == Array(0..<events.count))
        #expect(events[0].info == "Chi ha 10.0.0.2? Rispondi a 10.0.0.1" && events[0].bytes == 42)
        let echo = try #require(events.first { $0.proto == .icmp && $0.kind == .tx && $0.node == "a" })
        #expect(echo.info.hasPrefix("10.0.0.1 → 10.0.0.2 Echo request id=") && echo.info.hasSuffix(" seq=1 ttl=64"))
        #expect(echo.bytes == 98)
        let pdu = try #require(rt.pdu(echo.id))
        #expect(pdu.map(\.title) == ["Ethernet II", "IPv4", "ICMP"])
        #expect(pdu.map(\.bytes) == [98, 84, 64])
        let ip = Dictionary(uniqueKeysWithValues: pdu[1].fields.map { ($0.name, $0.value) })
        #expect(ip["TTL"] == "64" && ip["Protocollo"] == "1 (ICMP)" && ip["Lunghezza totale"] == "84 B" && ip["Flag"] == "0x2 (DF)")
        #expect(ip["Checksum header"]?.count == 6)
        #expect(pdu[2].fields.first == PduField(name: "Tipo", value: "8 (Echo request)"))
        #expect(rt.events(from: 0, limit: 2).map(\.id) == Array(events.suffix(2).map(\.id)))
        #expect(rt.pdu(1_000_000) == nil)
    }

    @Test func linkOptionsAndStateAreValidatedAppliedAndReported() throws {
        let rt = try lanRuntime()
        try rt.handle(.updateLink(id: "l1", options: LinkOptions(bandwidthBps: 10e6, propDelayNs: 2_000)))
        #expect(rt.snapshot().links[0].options == LinkOptions(bandwidthBps: 10e6, propDelayNs: 2_000))
        expectError("loss rate") { try rt.handle(.updateLink(id: "l1", options: LinkOptions(lossRate: 3))) }
        expectError("Unknown link") { try rt.handle(.setLinkUp(id: "zz", up: false)) }
        try rt.handle(.setLinkUp(id: "l2", up: false))
        #expect(rt.snapshot().links.map(\.up) == [true, false])
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 15_000)
        #expect(rt.snapshot().apps[0].lines.last?.hasSuffix("100% packet loss") == true)
    }

    @Test func poweringOffStopsAppsForgetsTablesAndRefusesNewApps() throws {
        let rt = try lanRuntime()
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        runFor(rt, wallMs: 1_500)
        #expect(rt.snapshot().nodes[0].arp.count == 1 && rt.snapshot().nodes[2].mac.count == 2)
        try rt.handle(.setPower(id: "a", on: false))
        try rt.handle(.setPower(id: "s", on: false))
        let s = rt.snapshot()
        #expect(!s.nodes[0].powered && s.nodes[0].arp.isEmpty && s.apps[0].done && s.nodes[2].mac.isEmpty)
        expectError("powered off") { try rt.handle(.ping(node: "a", target: "10.0.0.2")) }
        try rt.handle(.setPower(id: "a", on: true))
        #expect(rt.snapshot().nodes[0].powered)
    }

    @Test func loadRestoresLinkOptionsLinkStateAndPower() throws {
        let rt = Runtime()
        let opts = LinkOptions(bandwidthBps: 1e6, propDelayNs: 10_000, lossRate: 0.1, queueLimit: 5)
        let t = Topology(nodes: [
            TopologyNode(id: "a", kind: .pc, name: "PC1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: nil)], routes: [], powered: false),
            TopologyNode(id: "b", kind: .pc, name: "PC2", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: nil)], routes: []),
        ], links: [LinkView(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "b", iface: "eth0"), options: opts, up: false)])
        try rt.handle(.load(t))
        let s = rt.snapshot()
        #expect(s.links == t.links)
        #expect(s.nodes.map(\.powered) == [false, true])
        #expect(s.epoch == 1)
        var bad = t
        bad.links[0].options.lossRate = 7
        expectError("loss rate") { try rt.handle(.load(bad)) }
        #expect(rt.snapshot().links == t.links)
    }

    @Test func decodesFilesWithoutLinkOptionsOrPower() throws {
        let json = #"""
        {"version":1,"seed":1,"links":[{"id":"l","a":{"node":"a","iface":"eth0"},"b":{"node":"b","iface":"eth0"}}],
         "nodes":[{"id":"a","kind":"pc","name":"PC1","pos":{"x":0,"y":0},"ifaces":[{"name":"eth0"}],"routes":[]}]}
        """#
        let t = try JSONDecoder().decode(Topology.self, from: Data(json.utf8))
        #expect(t.links[0].options == LinkOptions() && t.links[0].up)
        #expect(t.nodes[0].powered)
    }

    @Test func reportsAnL2LoopAsAWarningAndBoundsTheWorkPerTick() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "s1", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "s2", kind: .switch, name: "SW2"))
        try rt.handle(.connect(id: "x", a: IfaceRef(node: "s1", iface: "Gi0/1"), b: IfaceRef(node: "s2", iface: "Gi0/1")))
        try rt.handle(.connect(id: "y", a: IfaceRef(node: "s1", iface: "Gi0/2"), b: IfaceRef(node: "s2", iface: "Gi0/2")))
        try rt.handle(.connect(id: "z", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s1", iface: "Gi0/3")))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.ping(node: "a", target: "10.0.0.9"))
        runFor(rt, wallMs: 1000)
        let s = rt.snapshot()
        #expect(Set(s.warnings.map(\.node)) == ["s1", "s2"])
        #expect(s.timeNs < 1_000_000_000) // the storm hit the per-tick budget: simulated time fell behind
        #expect(rt.events(from: 0).count == 5000)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh 2>&1 | grep -E "error:" | head`
Expected: compile errors for the new commands, fields and queries.

- [ ] **Step 3: Implement the protocol types**

In `Sources/PacEngine/Runtime/Protocol.swift`:

After `Pos`, add:

```swift
public enum SimMode: String, Codable, Sendable {
    /// The clock follows wall time × speed.
    case realtime
    /// The clock stands still; `step` runs to the next logged event, play steps slowly.
    case simulation
}

public enum Proto: String, CaseIterable, Sendable {
    case arp, icmp, udp
}
```

In `enum Command` add cases after `.traceroute`:

```swift
    case setMode(SimMode)
    case step
    case setPower(id: String, on: Bool)
    case updateLink(id: String, options: LinkOptions)
    case setLinkUp(id: String, up: Bool)
```

and in `key`:

```swift
        case .setMode: "setMode"
        case .step: "step"
        case .setPower: "setPower"
        case .updateLink: "updateLink"
        case .setLinkUp: "setLinkUp"
```

`NodeView`: add `public let powered: Bool` after `name`.

Replace `LinkView` with:

```swift
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
```

After `AppView` add:

```swift
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
```

In `Snapshot`: `public let version: Int` → `public internal(set) var version: Int`; add after `speed`:

```swift
    public let mode: SimMode
    /// Bumped when the network is reloaded: event sequence numbers restart.
    public let epoch: Int
    /// Events ever logged in this epoch; the next one gets this sequence number.
    public let eventCount: Int
```

and after `apps`: `public let warnings: [WarningView]`. Update `empty`:

```swift
    public static let empty = Snapshot(version: 0, seed: 1, timeNs: 0, running: true, speed: 1, mode: .realtime, epoch: 0,
                                       eventCount: 0, nodes: [], links: [], apps: [], warnings: [])
```

`TopologyNode`: add `public var powered: Bool`, init parameter `powered: Bool = true` (last), and:

```swift
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
```

- [ ] **Step 4: Implement event and PDU views**

Create `Sources/PacEngine/Runtime/EventViews.swift`:

```swift
import Foundation

private func hex(_ v: Int, digits: Int) -> String {
    "0x" + String(format: "%0\(digits)x", v)
}

private func icmpName(_ m: IcmpMessage) -> String {
    switch m.type {
    case ICMP_ECHO_REPLY: "Echo reply"
    case ICMP_ECHO_REQUEST: "Echo request"
    case ICMP_TIME_EXCEEDED: "Time exceeded"
    case ICMP_DEST_UNREACH:
        switch m.code {
        case UNREACH_NET: "Destination unreachable (net)"
        case UNREACH_HOST: "Destination unreachable (host)"
        case UNREACH_PORT: "Destination unreachable (port)"
        case UNREACH_FRAG_NEEDED: "Destination unreachable (fragmentation needed)"
        default: "Destination unreachable (code \(m.code))"
        }
    default: "Type \(m.type)"
    }
}

private func isEcho(_ m: IcmpMessage) -> Bool {
    m.type == ICMP_ECHO_REQUEST || m.type == ICMP_ECHO_REPLY
}

private func describe(_ a: ArpPacket) -> String {
    a.op == 1 ? "Chi ha \(formatIp(a.targetIp))? Rispondi a \(formatIp(a.senderIp))" : "\(formatIp(a.senderIp)) è \(a.senderMac)"
}

private func describe(_ p: Ipv4Packet) -> String {
    let ends = "\(formatIp(p.src)) → \(formatIp(p.dst))"
    switch p.payload {
    case .icmp(let m): return "\(ends) \(icmpName(m))" + (isEcho(m) ? " id=\(m.id) seq=\(m.seq)" : "") + " ttl=\(p.ttl)"
    case .udp(let u): return "\(ends) UDP \(u.srcPort) → \(u.dstPort) ttl=\(p.ttl)"
    }
}

/// Frame payload, or the bare packet of an L3 drop (no route, TTL, ARP timeout).
private func l3(_ e: SimEvent) -> L3? {
    e.frame?.payload ?? e.packet.map(L3.ipv4)
}

func eventView(_ e: SimEvent) -> EventView {
    let (proto, info): (Proto, String) = switch l3(e) {
    case .arp(let a)?: (.arp, describe(a))
    case .ipv4(let p)?: (p.proto == IPPROTO_ICMP ? .icmp : .udp, describe(p))
    case nil: (.arp, "") // every logged event carries a frame or a packet
    }
    return EventView(id: e.seq, timeNs: e.time, kind: e.kind, node: e.node, iface: e.iface, proto: proto,
                     frameId: e.frame?.id, bytes: e.frame?.size ?? e.packet?.size ?? 0, info: info, reason: e.reason?.rawValue)
}

private func field(_ name: String, _ value: String) -> PduField {
    PduField(name: name, value: value)
}

private func arpLayer(_ a: ArpPacket) -> PduLayer {
    PduLayer(title: "ARP", bytes: 28, fields: [
        field("Tipo hardware", "1 (Ethernet)"),
        field("Tipo protocollo", "0x0800 (IPv4)"),
        field("Lungh. hardware", "6"),
        field("Lungh. protocollo", "4"),
        field("Operazione", a.op == 1 ? "1 (request)" : "2 (reply)"),
        field("MAC mittente", a.senderMac),
        field("IP mittente", formatIp(a.senderIp)),
        field("MAC destinatario", a.targetMac),
        field("IP destinatario", formatIp(a.targetIp)),
    ])
}

private func ipLayers(_ p: Ipv4Packet) -> [PduLayer] {
    let ip = PduLayer(title: "IPv4", bytes: p.size, fields: [
        field("Versione", "4"),
        field("Lungh. header", "20 B (IHL 5)"),
        field("ToS", hex(Int(p.tos), digits: 2)),
        field("Lunghezza totale", "\(p.size) B"),
        field("Identificazione", "\(hex(Int(p.id), digits: 4)) (\(p.id))"),
        field("Flag", p.dontFragment ? "0x2 (DF)" : "0x0"),
        field("Offset frammento", "0"),
        field("TTL", "\(p.ttl)"),
        field("Protocollo", p.proto == IPPROTO_ICMP ? "1 (ICMP)" : "17 (UDP)"),
        field("Checksum header", hex(Int(p.checksum), digits: 4)),
        field("Sorgente", formatIp(p.src)),
        field("Destinazione", formatIp(p.dst)),
    ])
    switch p.payload {
    case .icmp(let m):
        var fields = [field("Tipo", "\(m.type) (\(icmpName(m)))"), field("Codice", "\(m.code)"),
                      field("Checksum", hex(Int(m.checksum), digits: 4))]
        if isEcho(m) { fields += [field("Identificatore", "\(m.id)"), field("Sequenza", "\(m.seq)")] }
        fields.append(field("Dati", isEcho(m) ? "\(m.data.count) B" : "\(m.data.count) B (header IP + 8 B del pacchetto originale)"))
        return [ip, PduLayer(title: "ICMP", bytes: m.size, fields: fields)]
    case .udp(let u):
        return [ip, PduLayer(title: "UDP", bytes: u.size, fields: [
            field("Porta sorgente", "\(u.srcPort)"),
            field("Porta destinazione", "\(u.dstPort)"),
            field("Lunghezza", "\(u.size) B"),
            field("Checksum", hex(Int(u.checksum), digits: 4) + (u.checksum == 0 ? " (non calcolato)" : "")),
            field("Dati", "\(u.data.count) B"),
        ])]
    }
}

/// Header-by-header view of the frame (or packet) an event logged, with real field values.
func pduLayers(_ e: SimEvent) -> [PduLayer] {
    var layers: [PduLayer] = []
    if let f = e.frame {
        layers.append(PduLayer(title: "Ethernet II", bytes: f.size, fields: [
            field("Destinazione", f.dst),
            field("Sorgente", f.src),
            field("EtherType", hex(Int(f.etherType), digits: 4) + (f.etherType == ETHERTYPE_ARP ? " (ARP)" : " (IPv4)")),
        ]))
    }
    switch l3(e) {
    case .arp(let a)?: layers.append(arpLayer(a))
    case .ipv4(let p)?: layers += ipLayers(p)
    case nil: break
    }
    return layers
}
```

- [ ] **Step 5: Implement the Runtime**

In `Sources/PacEngine/Runtime/Runtime.swift`, add after `MAX_STEP_MS`:

```swift
/// Simulation mode, play: one step per half second of wall time at 1×.
private let SIM_STEP_MS = 500.0
/// ponytail: fixed work budget per clock tick; a storm slows simulated time instead of freezing the app (spec §6 effective speed, not yet reported)
private let MAX_EVENTS_PER_ADVANCE = 200_000
/// A step whose events log nothing (only timers) gives up after this many.
private let MAX_SILENT_EVENTS = 100_000
```

In `Runtime` properties: remove `private var version = 0`; add

```swift
    public private(set) var mode = SimMode.realtime
    /// Bumped by `load`: a new Sim restarts event sequence numbers.
    public private(set) var epoch = 0
    private var stepCredit = 0.0
    private var last: Snapshot?
```

In `handle`, in `.ping` and `.traceroute` replace `try ipNode(node)` (the one passed to `Ping`/`Traceroute`) with `try liveIpNode(node)`; add cases:

```swift
        case let .setMode(value):
            mode = value
            running = value == .realtime
            stepCredit = 0
        case .step:
            step()
        case let .setPower(id, on):
            let node = try get(id)
            guard node.powered != on else { return }
            node.powered = on
            if !on {
                node.reset()
                for app in apps where app.node == id { app.program.stop() }
            }
        case let .updateLink(id, options):
            try link(id).update(options)
        case let .setLinkUp(id, up):
            try link(id).up = up
```

and in `.disconnect` replace `guard let link = links[id] else { throw EngineError("Unknown link \(id)") }` with `let link = try link(id)`.

Replace `advance`:

```swift
    public func advance(wallMs: Double) {
        guard running else { return }
        switch mode {
        case .realtime:
            sim.sched.runUntil(sim.now + Int((min(wallMs, MAX_STEP_MS) * Double(MS) * speed).rounded()), maxEvents: MAX_EVENTS_PER_ADVANCE)
        case .simulation:
            stepCredit += min(wallMs, MAX_STEP_MS) * speed
            while stepCredit >= SIM_STEP_MS {
                stepCredit -= SIM_STEP_MS
                step()
            }
        }
    }

    /// Runs scheduled events until one is logged (a frame sent, received or dropped) or none are left.
    private func step() {
        let before = sim.log.total
        var budget = MAX_SILENT_EVENTS
        while sim.log.total == before, budget > 0, sim.sched.step() { budget -= 1 }
    }

    /// Log entries from `seq` on, at most the newest `limit` (the UI pulls only what it has not seen).
    public func events(from seq: Int, limit: Int = 5000) -> [EventView] {
        sim.log.since(max(seq, sim.log.total - limit)).map(eventView)
    }

    /// Header-by-header view of one logged frame; nil once the ring buffer dropped it.
    public func pdu(_ seq: Int) -> [PduLayer]? {
        sim.log.event(seq).map(pduLayers)
    }
```

Rename the current `public func snapshot() -> Snapshot` to `private func build() -> Snapshot`, delete its `version += 1` line, and make it construct:

```swift
        return Snapshot(version: 0, seed: seed, timeNs: now, running: running, speed: speed, mode: mode, epoch: epoch,
                        eventCount: sim.log.total, nodes: nodeViews, links: linkViews, apps: appViews,
                        warnings: sim.warnings.map { WarningView(id: $0.id, node: $0.node, timeNs: $0.time) })
```

with `NodeView(id: id, kind: kind, name: node.name, powered: node.powered, …)` and `LinkView(id: id, a: …, b: …, options: l.opts, up: l.up)`. Add the public entry point:

```swift
    /// The version moves only when something visible changed, so a paused window does not redraw.
    public func snapshot() -> Snapshot {
        var s = build()
        s.version = last?.version ?? 0
        if s == last { return s }
        s.version += 1
        last = s
        return s
    }
```

Add helpers next to `ipNode`:

```swift
    private func link(_ id: String) throws -> Link {
        guard let link = links[id] else { throw EngineError("Unknown link \(id)") }
        return link
    }

    private func liveIpNode(_ id: String) throws -> IpNode {
        let ip = try ipNode(id)
        guard ip.powered else { throw EngineError("\(ip.name) is powered off") }
        return ip
    }
```

In `load(_:)` replace `for l in t.links { try next.handle(.connect(id: l.id, a: l.a, b: l.b)) }` with

```swift
        for l in t.links {
            try next.handle(.connect(id: l.id, a: l.a, b: l.b))
            try next.handle(.updateLink(id: l.id, options: l.options))
            if !l.up { try next.handle(.setLinkUp(id: l.id, up: false)) }
        }
```

after the routes loop add `for n in t.nodes where !n.powered { try next.handle(.setPower(id: n.id, on: false)) }`, and after `apps = []` add `epoch += 1` and `stepCredit = 0`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: all pass (113 + 10 = 123). If `reportsAnL2LoopAsAWarningAndBoundsTheWorkPerTick`'s time bound does not hold, measure the storm and ledger the observed numbers before changing the budget.

- [ ] **Step 7: Commit**

```bash
git add Sources/PacEngine Tests/PacEngineTests
git commit -m "feat(engine): add simulation mode with step, power, link updates, event/PDU queries and stable snapshot versions"
```

---

### Task 3: PacKit — event sync, flights, step, PDU selection, copy/paste, link fields, warnings

**Files:**
- Modify: `Sources/PacKit/Simulation.swift`, `Sources/PacKit/Editor.swift`, `Sources/PacKit/Topology+Helpers.swift`
- Create: `Sources/PacKit/EventHelpers.swift`
- Test: `Tests/PacKitTests/EditorTests.swift`, `Tests/PacKitTests/HelpersTests.swift`

**Interfaces:**
- Consumes: Task 2 (`EventView`, `PduLayer`, `Snapshot.epoch/eventCount/warnings/mode`, `Runtime.events/pdu/epoch`, new commands, `LinkOptions`, `NodeView.powered`, `TopologyNode.powered`).
- Produces:
  - `EngineClient.events(from seq: Int, epoch: Int) async -> [EventView]`, `EngineClient.pdu(_ seq: Int, epoch: Int) async -> [PduLayer]?`
  - `formatSimTime(_ ns: Int) -> String` ("1.000002672 s"); `filterEvents(_:protos:node:)`; `Proto.label`, `EventKind.label`; `FLIGHT_SECONDS = 0.4`; `struct Flight { id, frameId, link, from, proto, start, arrived }`; `updateFlights(_:with:links:now:)`, `pruneFlights(_:links:now:)`, `flightProgress(_:now:)`
  - `enum LinkField: String, CaseIterable { bandwidth, delay, loss, queue }` with `label`, `format(_:)`, `apply(_:to:) throws`; `formatBandwidth(_ bps: Double) -> String`
  - `Editor.events`, `.flights`, `.selectedEvent`, `.pdu`, `.warning`, `step()`, `selectEvent(_:)`, `copy(_:)`, `paste(at:)`, `duplicate(_:)`, `setLink(_:_:_:)`, `dismissWarning()`

- [ ] **Step 1: Write the failing tests**

In `Tests/PacKitTests/EditorTests.swift`, extend `Recording`:

```swift
    private(set) var fetches: [Int] = []

    func events(from seq: Int, epoch: Int) async -> [EventView] {
        fetches.append(seq)
        return await simulation.events(from: seq, epoch: epoch)
    }

    func pdu(_ seq: Int, epoch: Int) async -> [PduLayer]? {
        await simulation.pdu(seq, epoch: epoch)
    }
```

and make `clear()` reset both: `func clear() { sent = []; fetches = [] }`. Inside `struct EditorTests` add:

```swift
    private func lan() async -> (String, String) {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("SW1").id, node("PC1").id)
        await editor.connect(node("SW1").id, node("PC2").id)
        await editor.edit(.setIp(node: node("PC1").id, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: node("PC2").id, iface: "eth0", cidr: "10.0.0.2/24"))
        return (node("PC1").id, node("PC2").id)
    }

    @Test func stepsInSimulationModeAndShowsTheNewPduAndItsFlight() async {
        let (pc1, _) = await lan()
        await editor.run(.setMode(.simulation))
        await editor.run(.ping(node: pc1, target: "10.0.0.2"))
        await editor.step()
        #expect(editor.events.map { "\($0.kind.rawValue) \($0.proto.rawValue)" } == ["tx arp"])
        #expect(editor.selectedEvent == editor.events[0].id)
        #expect(editor.pdu?.map(\.title) == ["Ethernet II", "ARP"])
        #expect(editor.flights.map(\.from) == [pc1])
    }

    @Test func pullsOnlyNewEventsAndClearsThemWhenTheNetworkIsReloaded() async {
        let (pc1, _) = await lan()
        await editor.run(.ping(node: pc1, target: "10.0.0.2"))
        for _ in 0..<5 { await editor.tick(wallMs: 100) }
        let ids = editor.events.map(\.id)
        #expect(!ids.isEmpty && ids == Array(0..<ids.count))
        await client.clear()
        for _ in 0..<10 { await editor.tick(wallMs: 100) } // the second echo goes out at 1 s
        #expect(await client.fetches.first == ids.count)
        await editor.run(.setRunning(false))
        await client.clear()
        await editor.tick(wallMs: 100)
        #expect(await client.fetches.isEmpty)
        await editor.undo() // reloads the network: a new epoch
        #expect(editor.events.isEmpty && editor.flights.isEmpty && editor.selectedEvent == nil)
    }

    @Test func copiesPastesAndDuplicatesADeviceWithItsConfiguration() async {
        await editor.addDevice(.pc, at: Pos(x: 14, y: 14))
        let pc = node("PC1").id
        await editor.edit(.setIp(node: pc, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.addRoute(node: pc, cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        await editor.edit(.setPower(id: pc, on: false))
        editor.copy(pc)
        await editor.paste(at: nil)
        #expect(names == ["PC1", "PC2"])
        let copy = node("PC2")
        #expect(copy.ifaces[0].cidr == "10.0.0.1/24" && gatewayOf(copy) == "10.0.0.254" && !copy.powered)
        #expect(editor.positions[copy.id] == Pos(x: 42, y: 42))
        #expect(editor.selection == .node(copy.id))
        await editor.paste(at: Pos(x: 140, y: 0))
        #expect(editor.positions[node("PC3").id] == Pos(x: 140, y: 0))
        await editor.duplicate(copy.id)
        #expect(names == ["PC1", "PC2", "PC3", "PC4"])
        #expect(editor.positions[node("PC4").id] == Pos(x: 70, y: 70))
        await editor.undo()
        await editor.undo()
        await editor.undo()
        #expect(names == ["PC1"])
    }

    @Test func setsLinkPropertiesFromTextAndShowsParseErrorsOnTheField() async {
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("PC1").id, node("PC2").id)
        let link = editor.snapshot.links[0].id
        await editor.setLink(link, .bandwidth, "10")
        await editor.setLink(link, .loss, "2,5")
        #expect(editor.snapshot.links[0].options == LinkOptions(bandwidthBps: 10e6, lossRate: 0.025))
        await editor.setLink(link, .delay, "abc")
        #expect(editor.error == EditorError(key: "link:\(link):delay", message: "Invalid number: \"abc\""))
        await editor.setLink(link, .loss, "150")
        #expect(editor.error?.key == "link:\(link):loss" && editor.error?.message.contains("loss rate") == true)
        await editor.undo()
        #expect(editor.snapshot.links[0].options == LinkOptions(bandwidthBps: 10e6))
    }

    @Test func showsAnL2LoopWarningUntilDismissed() async {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("SW1").id, node("SW2").id)
        await editor.connect(node("SW1").id, node("SW2").id)
        await editor.connect(node("PC1").id, node("SW1").id)
        await editor.edit(.setIp(node: node("PC1").id, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.run(.ping(node: node("PC1").id, target: "10.0.0.9"))
        await editor.tick(wallMs: 10)
        #expect(editor.warning != nil)
        editor.dismissWarning()
        #expect(editor.warning == nil)
    }
```

Append inside `struct HelpersTests` in `Tests/PacKitTests/HelpersTests.swift`:

```swift
    @Test func formatsSimulatedTimeToTheNanosecond() {
        #expect(formatSimTime(0) == "0.000000000 s")
        #expect(formatSimTime(1_000_002_672) == "1.000002672 s")
    }

    @Test func filtersEventsByProtocolAndNode() {
        let e = { (id: Int, node: String, p: Proto) in
            EventView(id: id, timeNs: 0, kind: .tx, node: node, iface: "eth0", proto: p, frameId: id, bytes: 42, info: "", reason: nil)
        }
        let all = [e(0, "a", .arp), e(1, "b", .icmp), e(2, "a", .icmp)]
        #expect(filterEvents(all, protos: [.icmp], node: nil).map(\.id) == [1, 2])
        #expect(filterEvents(all, protos: Set(Proto.allCases), node: "a").map(\.id) == [0, 2])
    }

    @Test func animatesAFrameFromTxUntilItArrivesAndForAtLeastTheFlightTime() {
        let links = [LinkView(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "b", iface: "eth0"))]
        let tx = EventView(id: 0, timeNs: 0, kind: .tx, node: "a", iface: "eth0", proto: .icmp, frameId: 7, bytes: 98, info: "", reason: nil)
        let rx = EventView(id: 1, timeNs: 1172, kind: .rx, node: "b", iface: "eth0", proto: .icmp, frameId: 7, bytes: 98, info: "", reason: nil)
        var f = updateFlights([], with: [tx], links: links, now: 0)
        #expect(f.map(\.from) == ["a"] && !f[0].arrived)
        #expect(flightProgress(f[0], now: 0.2) == 0.5)
        #expect(flightProgress(f[0], now: 9) == 1)
        #expect(pruneFlights(f, links: links, now: 99).count == 1) // still on the wire: waits for the next step
        f = updateFlights(f, with: [rx], links: links, now: 0.1)
        #expect(f.count == 1 && f[0].arrived)
        #expect(pruneFlights(f, links: links, now: 0.5).isEmpty)
        #expect(pruneFlights(f, links: [], now: 0.1).isEmpty) // cable removed
    }

    @Test func parsesAndFormatsLinkFields() throws {
        let o = LinkOptions()
        #expect(LinkField.allCases.map { $0.format(o) } == ["1000", "0.5", "0", "1000"])
        #expect(try LinkField.bandwidth.apply(" 0,1 ", to: o).bandwidthBps == 100_000)
        #expect(try LinkField.delay.apply("2.5", to: o).propDelayNs == 2_500)
        #expect(try LinkField.loss.apply("1.1", to: o).lossRate == 0.011)
        #expect(LinkField.loss.format(try LinkField.loss.apply("1.1", to: o)) == "1.1")
        for bad in ["abc", "", "nan", "inf", "1e300"] {
            expectError("Invalid number") { _ = try LinkField.delay.apply(bad, to: o) }
        }
        expectError("Invalid number") { _ = try LinkField.queue.apply("2.5", to: o) }
    }

    @Test func formatsBandwidthWithUnits() {
        #expect(formatBandwidth(1e9) == "1 Gb/s")
        #expect(formatBandwidth(10e6) == "10 Mb/s")
        #expect(formatBandwidth(1_500) == "1.5 kb/s")
        #expect(formatBandwidth(64) == "64 b/s")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh 2>&1 | grep -E "error:" | head`
Expected: compile errors for the missing PacKit API.

- [ ] **Step 3: Implement the client queries**

In `Sources/PacKit/Simulation.swift`, add to `protocol EngineClient`:

```swift
    /// Log entries from `seq` on; empty when `epoch` is no longer current (the network was reloaded).
    func events(from seq: Int, epoch: Int) async -> [EventView]
    /// Header-by-header view of one logged frame; nil once it left the log or the network was reloaded.
    func pdu(_ seq: Int, epoch: Int) async -> [PduLayer]?
```

and to `actor Simulation`:

```swift
    public func events(from seq: Int, epoch: Int) -> [EventView] {
        epoch == runtime.epoch ? runtime.events(from: seq) : []
    }

    public func pdu(_ seq: Int, epoch: Int) -> [PduLayer]? {
        epoch == runtime.epoch ? runtime.pdu(seq) : nil
    }
```

- [ ] **Step 4: Implement the helpers**

Create `Sources/PacKit/EventHelpers.swift`:

```swift
import PacEngine

extension Proto {
    public var label: String { rawValue.uppercased() }
}

extension EventKind {
    public var label: String { rawValue.uppercased() }
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

private func link(at node: String, _ iface: String?, in links: [LinkView]) -> LinkView? {
    links.first { ($0.a.node == node && $0.a.iface == iface) || ($0.b.node == node && $0.b.iface == iface) }
}

public func updateFlights(_ flights: [Flight], with events: [EventView], links: [LinkView], now: Double) -> [Flight] {
    var out = flights
    for e in events {
        guard let frame = e.frameId, let cable = link(at: e.node, e.iface, in: links) else { continue }
        if e.kind == .tx {
            out.append(Flight(id: e.id, frameId: frame, link: cable.id, from: e.node, proto: e.proto, start: now))
        } else if let i = out.firstIndex(where: { !$0.arrived && $0.frameId == frame && $0.link == cable.id && $0.from != e.node }) {
            out[i].arrived = true
        }
    }
    return pruneFlights(Array(out.suffix(MAX_FLIGHTS)), links: links, now: now)
}

/// Keeps flights still crossing the screen and whose cable still exists.
public func pruneFlights(_ flights: [Flight], links: [LinkView], now: Double) -> [Flight] {
    flights.filter { f in !(f.arrived && now - f.start >= FLIGHT_SECONDS) && links.contains { $0.id == f.link } }
}

/// Fraction of the cable covered, from the sender.
public func flightProgress(_ f: Flight, now: Double) -> Double {
    min(max((now - f.start) / FLIGHT_SECONDS, 0), 1)
}
```

Append to `Sources/PacKit/Topology+Helpers.swift`:

```swift
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
```

In `makeTopology`, pass `powered: n.powered` to `TopologyNode(...)`.

- [ ] **Step 5: Implement the Editor additions**

In `Sources/PacKit/Editor.swift` add `import Foundation`. Properties (after `error`):

```swift
    /// Newest log entries pulled from the engine (at most `eventLimit`), oldest first.
    public private(set) var events: [EventView] = []
    /// PDUs being drawn on cables.
    public private(set) var flights: [Flight] = []
    public private(set) var selectedEvent: Int?
    /// Headers of `selectedEvent`; nil while loading or once the engine forgot it.
    public private(set) var pdu: [PduLayer]?
    private var dismissedWarning = 0
    @ObservationIgnored private var eventCursor = 0
    @ObservationIgnored private var eventEpoch = 0
```

statics: `private static let eventLimit = 5000` and

```swift
    /// Process-wide device clipboard.
    // ponytail: in-memory, not NSPasteboard; enough to copy between windows of this app
    private static var clipboard: TopologyNode?
```

Add `public var warning: WarningView? { snapshot.warnings.last.flatMap { $0.id > dismissedWarning ? $0 : nil } }`.

Add the sync and calls:

```swift
    /// Pulls only log entries newer than those shown and starts their animations.
    func syncEvents() async {
        let s = snapshot
        if s.epoch != eventEpoch {
            eventEpoch = s.epoch
            eventCursor = 0
            events = []
            flights = []
            selectedEvent = nil
            pdu = nil
            dismissedWarning = 0
        }
        guard s.eventCount > eventCursor else { return }
        let batch = await client.events(from: eventCursor, epoch: s.epoch)
        let fresh = batch.filter { $0.id >= eventCursor }
        guard eventEpoch == s.epoch, let last = fresh.last else { return }
        eventCursor = last.id + 1
        events = Array((events + fresh).suffix(Self.eventLimit))
        flights = updateFlights(flights, with: fresh, links: snapshot.links, now: Date.timeIntervalSinceReferenceDate)
    }
```

Call `await syncEvents()` right after `accept(...)` in `loadNow`, `runNow`, and `restore` (after its `do/catch`, before `positions = …`). Replace `tick`:

```swift
    public func tick(wallMs: Double) async {
        accept(await client.advance(wallMs: wallMs))
        await syncEvents()
        let kept = pruneFlights(flights, links: snapshot.links, now: Date.timeIntervalSinceReferenceDate)
        if kept.count != flights.count { flights = kept }
    }
```

Step, selection, warnings:

```swift
    /// Simulation mode: runs to the next logged event and opens its PDU (the "current PDU").
    public func step() async {
        await serialized {
            let before = self.eventCursor
            guard await self.runNow(.step, key: nil), self.eventCursor > before, let last = self.events.last else { return }
            await self.selectEventNow(last.id)
        }
    }

    public func selectEvent(_ id: Int?) async {
        await serialized { await self.selectEventNow(id) }
    }

    private func selectEventNow(_ id: Int?) async {
        selectedEvent = id
        pdu = nil
        guard let id else { return }
        let layers = await client.pdu(id, epoch: eventEpoch)
        if selectedEvent == id { pdu = layers }
    }

    public func dismissWarning() {
        dismissedWarning = snapshot.warnings.last?.id ?? dismissedWarning
    }
```

Copy, paste, duplicate:

```swift
    public func copy(_ id: String) {
        Self.clipboard = current.nodes.first { $0.id == id }
    }

    /// Pastes the copied device at `pos`, or 28 pt below-right of the last copy.
    public func paste(at pos: Pos?) async {
        await serialized {
            guard var src = Self.clipboard else { return }
            src.pos = pos ?? Pos(x: src.pos.x + 28, y: src.pos.y + 28)
            if pos == nil { Self.clipboard = src }
            await self.insertCopy(of: src)
        }
    }

    public func duplicate(_ id: String) async {
        await serialized {
            guard var src = self.current.nodes.first(where: { $0.id == id }) else { return }
            src.pos = Pos(x: src.pos.x + 28, y: src.pos.y + 28)
            await self.insertCopy(of: src)
        }
    }

    /// Adds a device configured like `src` (addresses, static routes, power; no cables) in one undo step.
    private func insertCopy(of src: TopologyNode) async {
        let id = newId()
        positions[id] = src.pos
        var cmds: [Command] = [.addNode(id: id, kind: src.kind, name: defaultName(src.kind, existing: snapshot.nodes))]
        cmds += src.ifaces.compactMap { i in i.cidr.map { Command.setIp(node: id, iface: i.name, cidr: $0) } }
        cmds += src.routes.map { Command.addRoute(node: id, cidr: $0.cidr, nextHop: $0.nextHop) }
        if !src.powered { cmds.append(.setPower(id: id, on: false)) }
        if await editNow(cmds, key: "paste") { selection = .node(id) }
    }
```

Link fields:

```swift
    /// Applies one link property typed in the inspector; parse and range errors show on that field.
    public func setLink(_ id: String, _ field: LinkField, _ text: String) async {
        await serialized {
            let key = "link:\(id):\(field.rawValue)"
            guard let link = self.snapshot.links.first(where: { $0.id == id }) else { return }
            let options: LinkOptions
            do {
                options = try field.apply(text, to: link.options)
            } catch {
                self.fail(key, error)
                return
            }
            await self.editNow([.updateLink(id: id, options: options)], key: key)
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: all pass (123 + 10 = 133).

- [ ] **Step 7: Commit**

```bash
git add Sources/PacKit Tests/PacKitTests
git commit -m "feat(kit): pull new events, derive packet flights, step, PDU selection, copy/paste/duplicate and link fields"
```

---

### Task 4: App — time modes, bottom panel with events and PDU inspector, packet animation, loop warning

**Files:**
- Modify: `Sources/PacTrack/PacTrackApp.swift`, `Sources/PacTrack/MainContent.swift`, `Sources/PacTrack/OutputPanel.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/Controls.swift`, `Sources/PacTrack/Theme.swift`, `Sources/PacTrack/SelfTest.swift`
- Create: `Sources/PacTrack/BottomPanel.swift`, `Sources/PacTrack/EventsPanel.swift`

**Interfaces:**
- Consumes: Task 3 (`Editor.events/flights/selectedEvent/pdu/warning/step/selectEvent/dismissWarning`, `formatSimTime`, `filterEvents`, `flightProgress`, labels).
- Produces: `Theme.warn`, `Theme.proto(_:)`; `BottomPanel`, `EventsPanel`, `PduInspector`, `WarningBanner`; `SelfTest.scenario` M2b checks.

- [ ] **Step 1: RED — selftest scenario and baseline PNG**

Run `scripts/selftest.sh build/m2b-t4-red.png` and Read the PNG (current UI: no mode switch, no events tab). In `SelfTest.scenario`, before `if !render(editor, to: output)`, add:

```swift
        // M2b: Simulation mode, step, events, PDU, flights
        await editor.run(.setMode(.simulation))
        if editor.snapshot.running { failures.append("simulation mode must stop the clock") }
        let paused = editor.snapshot.version
        await editor.tick(wallMs: 100)
        if editor.snapshot.version != paused { failures.append("a paused tick bumped the snapshot version") }
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.2"))
        await editor.step()
        if editor.events.last.map({ "\($0.kind.rawValue) \($0.proto.rawValue)" }) != "tx icmp" {
            failures.append("step: last event \(String(describing: editor.events.last))")
        }
        if editor.pdu?.map(\.title) != ["Ethernet II", "IPv4", "ICMP"] { failures.append("PDU \(String(describing: editor.pdu))") }
        if editor.flights.isEmpty { failures.append("no packet animated after a step") }
        failures += await loopScenario()
```

and add to `SelfTest`:

```swift
    /// Two switches cabled twice: the ARP broadcast circulates and the UI must warn.
    private static func loopScenario() async -> [String] {
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        await editor.addDevice(.switch, at: Pos(x: 200, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 0, y: 200))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("SW2"))
        await editor.connect(id("SW1"), id("SW2"))
        await editor.connect(id("PC1"), id("SW1"))
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.9"))
        for _ in 0..<3 { await editor.tick(wallMs: 100) }
        return editor.warning == nil ? ["no L2 loop warning"] : []
    }
```

Run `scripts/selftest.sh build/m2b-t4-red.png`. Expected: the editor-level checks pass (Task 3 logic), and the PNG is RED — no mode switch, no Eventi tab, no PDU inspector, no packet on the cable. Read it.

- [ ] **Step 2: Theme**

In `Theme`, add:

```swift
    static let warn = Color(hex: 0xF0A732)

    /// Spec §7.3 protocol colors.
    static func proto(_ p: Proto) -> Color {
        switch p {
        case .arp: Color(hex: 0xF0A732)
        case .icmp: Color(hex: 0xE5507A)
        case .udp: Color(hex: 0x2FBFC4)
        }
    }
```

- [ ] **Step 3: Toolbar mode switch, step and clock**

In `SimulationToolbar.body`, replace the `ToolbarItemGroup(placement: .primaryAction) { … }` with:

```swift
        ToolbarItemGroup(placement: .primaryAction) {
            let s = editor.snapshot
            Picker("Modalità", selection: Binding(get: { s.mode }, set: { m in Task { await editor.run(.setMode(m)) } })) {
                Text("Realtime").tag(SimMode.realtime)
                Text("Simulation").tag(SimMode.simulation)
            }
            .pickerStyle(.segmented)
            .help("Realtime: il tempo scorre. Simulation: orologio fermo, avanzi evento per evento.")
            Button { Task { await editor.run(.setRunning(!s.running)) } } label: {
                Label(s.running ? "Pausa" : "Avvia", systemImage: s.running ? "pause.fill" : "play.fill")
            }
            .help(s.mode == .simulation ? "Avanza da solo, un evento alla volta" : "Avvia o ferma il tempo (Spazio)")
            Button { Task { await editor.step() } } label: { Label("Passo", systemImage: "forward.frame.fill") }
                .disabled(s.mode != .simulation)
                .help("Esegue il prossimo evento (tasto .)")
            Picker("Velocità", selection: Binding(get: { s.speed }, set: { v in Task { await editor.run(.setSpeed(v)) } })) {
                ForEach(SPEEDS, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .frame(width: 90)
            Text(s.mode == .simulation ? "t = " + formatSimTime(s.timeNs) : String(format: "t = %.3f s", Double(s.timeNs) / 1e9))
                .font(Theme.mono)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 150, alignment: .trailing)
        }
```

- [ ] **Step 4: Bottom panel with tabs**

Create `Sources/PacTrack/BottomPanel.swift`:

```swift
import PacKit
import SwiftUI

private enum BottomTab: String, CaseIterable {
    case events = "Eventi", output = "Output app"
}

/// Resizable panel under the canvas (spec §7.1 ⑤). Metriche arrives with M4.
struct BottomPanel: View {
    @Bindable var editor: Editor
    @State private var tab = BottomTab.events

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(BottomTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch tab {
            case .events: EventsPanel(editor: editor)
            case .output: OutputPanel(editor: editor)
            }
        }
        .background(Theme.panel)
    }
}
```

In `OutputPanel.body` delete the title row (`Text("Output app")…` and the `Divider()` under it): the tab names the panel now.

In `MainContent.body`, replace the inner `VStack(spacing: 0) { CanvasView… OutputPanel… }` with:

```swift
            VSplitView {
                CanvasView(editor: editor)
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            ErrorBanner(editor: editor)
                            WarningBanner(editor: editor)
                        }
                    }
                    .frame(minHeight: 220)
                BottomPanel(editor: editor)
                    .frame(minHeight: 110, idealHeight: 240)
            }
```

- [ ] **Step 5: Events list and PDU inspector**

Create `Sources/PacTrack/EventsPanel.swift`:

```swift
import PacEngine
import PacKit
import SwiftUI

/// Event list (filterable by protocol and node) beside the PDU inspector.
struct EventsPanel: View {
    @Bindable var editor: Editor
    @State private var protos = Set(Proto.allCases)
    @State private var node: String?

    static let widths: [CGFloat] = [104, 38, 40, 130]

    var body: some View {
        let shown = filterEvents(editor.events, protos: protos, node: node)
        HSplitView {
            VStack(spacing: 0) {
                filters(count: shown.count)
                Divider()
                list(shown)
            }
            .frame(minWidth: 440)
            PduInspector(editor: editor)
                .frame(minWidth: 240, idealWidth: 330)
        }
    }

    private func filters(count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Proto.allCases, id: \.self) { p in
                let on = protos.contains(p)
                Button {
                    if on { protos.remove(p) } else { protos.insert(p) }
                } label: {
                    Text(p.label)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.proto(p).opacity(on ? 0.22 : 0)))
                        .overlay(Capsule().stroke(Theme.proto(p).opacity(on ? 1 : 0.35)))
                        .foregroundStyle(on ? Theme.proto(p) : Theme.muted)
                }
                .buttonStyle(.plain)
                .help(on ? "Nascondi \(p.label)" : "Mostra \(p.label)")
                .accessibilityIdentifier("filter-\(p.rawValue)")
            }
            Picker("Nodo", selection: $node) {
                Text("Tutti i nodi").tag(String?.none)
                ForEach(editor.snapshot.nodes) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(width: 140)
            Spacer()
            Text("\(count) eventi").font(Theme.small).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func list(_ shown: [EventView]) -> some View {
        let names = Dictionary(uniqueKeysWithValues: editor.snapshot.nodes.map { ($0.id, $0.name) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text("Nessun evento: avvia il tempo o fai un ping (in Simulation premi Passo).")
                            .foregroundStyle(Theme.muted)
                            .padding(10)
                    }
                    ForEach(shown) { e in
                        EventRow(event: e, node: names[e.node] ?? "(rimosso)", selected: editor.selectedEvent == e.id)
                            .id(e.id)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await editor.selectEvent(e.id) } }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .onChange(of: shown.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .accessibilityIdentifier("events")
    }
}

private struct EventRow: View {
    let event: EventView
    let node: String
    let selected: Bool

    var body: some View {
        let w = EventsPanel.widths
        HStack(spacing: 8) {
            Text(formatSimTime(event.timeNs)).foregroundStyle(Theme.muted).frame(width: w[0], alignment: .trailing)
            Text(event.kind.label).foregroundStyle(event.kind == .drop ? Theme.err : Theme.muted).frame(width: w[1], alignment: .leading)
            Text(event.proto.label).foregroundStyle(Theme.proto(event.proto)).frame(width: w[2], alignment: .leading)
            Text("\(node) \(event.iface ?? "")").lineLimit(1).frame(width: w[3], alignment: .leading)
            Text((event.reason.map { "[\($0)] " } ?? "") + event.info + " · \(event.bytes) B").lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(selected ? Theme.accent.opacity(0.35) : Color.clear)
    }
}

/// The selected frame, header by header, with real field values (spec §7.1 ⑤).
struct PduInspector: View {
    let editor: Editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if editor.selectedEvent == nil {
                    Text("Seleziona un evento per vederne la PDU header per header.").foregroundStyle(Theme.muted)
                } else if let layers = editor.pdu {
                    ForEach(layers.indices, id: \.self) { PduLayerView(layer: layers[$0]) }
                } else {
                    Text("PDU non più disponibile nel registro eventi.").foregroundStyle(Theme.muted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .accessibilityIdentifier("pdu-inspector")
    }
}

private struct PduLayerView: View {
    let layer: PduLayer
    @State private var open = true

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(layer.fields.indices, id: \.self) { i in
                    GridRow {
                        Text(layer.fields[i].name).foregroundStyle(Theme.muted)
                        Text(layer.fields[i].value).foregroundStyle(Theme.fgStrong).textSelection(.enabled)
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.leading, 4)
        } label: {
            Text("\(layer.title) · \(layer.bytes) B").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.fgStrong)
        }
    }
}
```

- [ ] **Step 6: Packet animation layer and `.` key**

In `CanvasView.body`, inside the `ZStack`, between the nodes `ForEach` and `if let wire`, add:

```swift
                if !editor.flights.isEmpty {
                    TimelineView(.animation) { context in
                        let now = context.date.timeIntervalSinceReferenceDate
                        ForEach(editor.flights) { flight in
                            if let link = editor.snapshot.links.first(where: { $0.id == flight.link }) {
                                let a = center(flight.from)
                                let b = center(link.a.node == flight.from ? link.b.node : link.a.node)
                                let t = flightProgress(flight, now: now)
                                PduTag(proto: flight.proto).position(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
```

After `.onKeyPress(.space) { … }` add:

```swift
            .onKeyPress(KeyEquivalent(".")) {
                guard editor.snapshot.mode == .simulation else { return .ignored }
                Task { await editor.step() }
                return .handled
            }
```

At the end of the file:

```swift
/// A PDU on a cable: protocol name on its spec color.
private struct PduTag: View {
    let proto: Proto

    var body: some View {
        Text(proto.label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(Theme.bg)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.proto(proto)))
    }
}
```

- [ ] **Step 7: Loop warning banner**

Append to `Sources/PacTrack/Controls.swift`:

```swift
/// Non-blocking L2 loop warning (spec §5.4, §9); stays until dismissed or a new loop is detected.
struct WarningBanner: View {
    let editor: Editor

    var body: some View {
        if let w = editor.warning {
            let name = editor.snapshot.nodes.first { $0.id == w.node }?.name ?? w.node
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.warn)
                Text("Possibile loop L2 su \(name): lo stesso frame è tornato più volte (t = \(formatSimTime(w.timeNs))). Controlla i collegamenti ridondanti tra switch.")
                    .foregroundStyle(Theme.fgStrong)
                Button { editor.dismissWarning() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Chiudi")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.warn.opacity(0.7)))
            .padding(10)
            .accessibilityIdentifier("warning-banner")
        }
    }
}
```

- [ ] **Step 8: GREEN — selftest and PNG**

Run: `scripts/selftest.sh build/m2b-t4.png && scripts/test.sh 2>&1 | tail -1`
Expected: `SELFTEST OK`; 133 tests pass. Read `build/m2b-t4.png`: Eventi tab with the ARP/ICMP rows, the PDU inspector showing Ethernet II / IPv4 / ICMP with field values, an `ICMP` tag on the PC1 cable.

- [ ] **Step 9: Commit**

```bash
git add Sources/PacTrack
git commit -m "feat(app): add Realtime/Simulation switch with step, event list with PDU inspector, packet animation and loop warning"
```

---

### Task 5: App — link properties and faults, power, copy/paste/duplicate, palette search

**Files:**
- Modify: `Sources/PacTrack/InspectorView.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/DeviceNodeView.swift`, `Sources/PacTrack/PacTrackApp.swift`, `Sources/PacTrack/PaletteView.swift`, `Sources/PacTrack/Controls.swift`, `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: Task 3 (`setLink`, `LinkField`, `formatBandwidth`, `copy/paste/duplicate`), Task 2 commands.
- Produces: `PaletteView.groups(matching:)`; link inspector fields keyed `link:<id>:<field>`.

- [ ] **Step 1: RED — selftest**

In `SelfTest.scenario`, after the M2b step block, add:

```swift
        // M2b: link properties and faults, power, duplicate, palette search
        let cable = editor.snapshot.links[0].id
        await editor.setLink(cable, .bandwidth, "100")
        await editor.setLink(cable, .delay, "veloce")
        if editor.error?.key != "link:\(cable):delay" { failures.append("link field error: \(String(describing: editor.error))") }
        await editor.edit(.setLinkUp(id: editor.snapshot.links[1].id, up: false))
        await editor.duplicate(id("PC2"))
        await editor.edit(.setPower(id: id("PC3"), on: false))
        if editor.snapshot.nodes.first(where: { $0.name == "PC3" })?.powered != false { failures.append("PC3 should be off") }
        if PaletteView.groups(matching: "rou").map(\.1) != [[.router]] { failures.append("palette search") }
        if !PaletteView.groups(matching: "zzz").isEmpty { failures.append("palette search should find nothing") }
        editor.select(.link(cable))
```

Run `scripts/selftest.sh build/m2b-t5-red.png`. Expected: compile error (`groups(matching:)`) — RED. Read `build/m2b-t4.png` as the "before" picture.

- [ ] **Step 2: Link inspector**

Replace `LinkInspector.body` in `Sources/PacTrack/InspectorView.swift`:

```swift
    var body: some View {
        let name = { (id: String) in editor.snapshot.nodes.first { $0.id == id }?.name ?? "?" }
        VStack(alignment: .leading, spacing: 10) {
            Text("Collegamento Ethernet").foregroundStyle(Theme.fgStrong)
            Text("\(name(link.a.node)) \(link.a.iface) ↔ \(name(link.b.node)) \(link.b.iface)").font(Theme.mono)
            Toggle("Collegamento attivo", isOn: Binding(get: { link.up }, set: { up in Task { await editor.edit(.setLinkUp(id: link.id, up: up)) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("link-up")
            ForEach(LinkField.allCases, id: \.self) { field in
                CommitField(label: field.label, value: field.format(link.options), errorKey: "link:\(link.id):\(field.rawValue)", editor: editor) {
                    await editor.setLink(link.id, field, $0)
                }
            }
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
        .padding(12)
    }
```

In `ErrorBanner.fieldPrefixes` add `"link:"`.

- [ ] **Step 3: Cable look and menu, paste on canvas**

In `CanvasView.cable(_:)`: stroke `line.stroke(selected ? Theme.accent : link.up ? Theme.muted : Theme.err, style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: link.up ? [] : [5, 4]))`; label text `"\(link.a.iface) ↔ \(link.b.iface) · \(formatBandwidth(link.options.bandwidthBps))"`; replace the context menu with:

```swift
        .contextMenu {
            Button("Proprietà") { editor.select(.link(link.id)) }
            Button(link.up ? "Simula guasto" : "Ripristina") { Task { await editor.edit(.setLinkUp(id: link.id, up: !link.up)) } }
            Divider()
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
```

In `paneMenu`, after the `Menu("Aggiungi dispositivo")`, add:

```swift
        Button("Incolla") {
            let at = snap(toWorld(hover))
            Task { await editor.paste(at: at) }
        }
```

- [ ] **Step 4: Power look, node menu, inspector power button**

In `DeviceNodeView.body`: LED `Circle().fill(!node.powered ? Theme.err : node.ifaces.contains(where: \.linked) ? Theme.ok : Theme.muted)`; after `.overlay(alignment: .bottom) { handle }` add `.opacity(node.powered ? 1 : 0.5)`.

In `NodeMenu.body`: add `.disabled(targets.isEmpty || !node.powered)` instead of `.disabled(targets.isEmpty)` on both app menus; replace `Divider()` + `Elimina` with:

```swift
        Button(node.powered ? "Spegni" : "Accendi") { Task { await editor.edit(.setPower(id: node.id, on: !node.powered)) } }
        Divider()
        Button("Duplica") { Task { await editor.duplicate(node.id) } }
        Button("Copia") { editor.copy(node.id) }
        Divider()
        Button("Elimina", role: .destructive) { Task { await editor.remove(nodes: [node.id], links: []) } }
```

In `NodeInspector.body`, in the header `HStack`, after the `CommitField`:

```swift
                Button { Task { await editor.edit(.setPower(id: node.id, on: !node.powered)) } } label: {
                    Image(systemName: "power").foregroundStyle(node.powered ? Theme.ok : Theme.err)
                }
                .buttonStyle(.borderless)
                .help(node.powered ? "Spegni" : "Accendi")
                .accessibilityIdentifier("power")
```

- [ ] **Step 5: Pasteboard commands**

In `EditCommands`, add a helper and a second group:

```swift
    private func send(_ action: String) {
        NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }

    private var selectedNode: String? {
        if case .node(let id)? = editor?.selection { id } else { nil }
    }
```

and after the undo/redo `CommandGroup`:

```swift
        // Text fields keep the standard editing actions; elsewhere the shortcuts act on devices.
        CommandGroup(replacing: .pasteboard) {
            Button("Taglia") { if typing { send("cut:") } }
                .keyboardShortcut("x")
            Button("Copia") {
                if typing { send("copy:") } else if let id = selectedNode { editor?.copy(id) }
            }
            .keyboardShortcut("c")
            Button("Incolla") {
                if typing { send("paste:") } else { Task { await editor?.paste(at: nil) } }
            }
            .keyboardShortcut("v")
            Button("Duplica") {
                if let id = selectedNode { Task { await editor?.duplicate(id) } }
            }
            .keyboardShortcut("d")
            Button("Seleziona tutto") { if typing { send("selectAll:") } }
                .keyboardShortcut("a")
        }
```

- [ ] **Step 6: Palette search**

Replace `PaletteView` with:

```swift
struct PaletteView: View {
    private static let all: [(String, [DeviceKind])] = [("Rete", [.router, .switch, .hub]), ("Host", [.pc, .laptop, .server])]
    @State private var query = ""

    /// Categories with the devices whose name (or category) contains `query`.
    static func groups(matching query: String) -> [(String, [DeviceKind])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.compactMap { title, kinds in
            let hits = q.isEmpty || title.localizedCaseInsensitiveContains(q) ? kinds : kinds.filter { $0.label.localizedCaseInsensitiveContains(q) }
            return hits.isEmpty ? nil : (title, hits)
        }
    }

    var body: some View {
        let groups = Self.groups(matching: query)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Cerca", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("palette-search")
            if groups.isEmpty { Text("Nessun dispositivo").font(Theme.small).foregroundStyle(Theme.muted) }
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

- [ ] **Step 7: GREEN — selftest and PNG**

Run: `scripts/selftest.sh build/m2b-t5.png && scripts/test.sh 2>&1 | tail -1`
Expected: `SELFTEST OK`, 133 tests. Read `build/m2b-t5.png`: palette search field; PC3 dimmed with red LED; second cable dashed red; cable labels with `100 Mb/s`/`1 Gb/s`; link inspector with the toggle and four fields, the delay field showing the red `Invalid number` error.

- [ ] **Step 8: Commit**

```bash
git add Sources/PacTrack
git commit -m "feat(app): add link properties and fault simulation, device power, copy/paste/duplicate and palette search"
```

---

### Task 6: App — M2a deferred fixes, manual checklist, bundle

**Files:**
- Modify: `Sources/PacTrack/PacTrackApp.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/Controls.swift`, `Sources/PacTrack/SelfTest.swift`
- Create: `docs/manual-checks/m2b.md`

**Interfaces:**
- Produces: `CanvasView.zoomed(offset:zoom:to:anchor:) -> CGSize` (static).

- [ ] **Step 1: RED — selftest geometry check**

In `SelfTest.scenario`, before rendering, add:

```swift
        // Pinch anchored at the pointer: the world point under the fingers stays put.
        let o = CanvasView.zoomed(offset: CGSize(width: 10, height: 20), zoom: 1, to: 2, anchor: CGPoint(x: 110, y: 120))
        if o != CGSize(width: -90, height: -80) { failures.append("anchored zoom offset \(o)") }
```

Run `scripts/selftest.sh build/m2b-t6-red.png`. Expected: compile error (`zoomed` missing) — RED.

- [ ] **Step 2: Anchored pinch zoom, two-finger scroll pan, menu point frozen at mouse-down**

In `CanvasView`: replace `@State private var zoomStart: CGFloat?` with

```swift
    @State private var zoomStart: (zoom: CGFloat, offset: CGSize)?
    @State private var hovering = false
    /// Pointer position when the last mouse button went down: where a context-menu action inserts.
    @State private var menuPoint = CGPoint.zero
    @State private var monitor: Any?
```

add `import AppKit`; the static helper:

```swift
    /// Pan offset that keeps the world point under `anchor` fixed while the zoom changes.
    static func zoomed(offset: CGSize, zoom: CGFloat, to newZoom: CGFloat, anchor: CGPoint) -> CGSize {
        CGSize(width: anchor.x - (anchor.x - offset.width) / zoom * newZoom,
               height: anchor.y - (anchor.y - offset.height) / zoom * newZoom)
    }
```

replace the `MagnifyGesture` `onChanged`/`onEnded`:

```swift
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? (zoom, offset)
                        zoomStart = start
                        let z = min(max(start.zoom * value.magnification, 0.3), 3)
                        offset = Self.zoomed(offset: start.offset, zoom: start.zoom, to: z, anchor: value.startLocation)
                        zoom = z
                    }
                    .onEnded { _ in zoomStart = nil }
```

replace the `onContinuousHover` closure:

```swift
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                switch phase {
                case .active(let p):
                    hover = p
                    hovering = true
                case .ended:
                    hovering = false
                }
            }
            .onAppear {
                // SwiftUI has no scroll-wheel gesture: two-finger scroll pans the canvas under the pointer.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { event in
                    guard hovering else { return event }
                    if event.type != .scrollWheel {
                        menuPoint = hover
                        return event
                    }
                    let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    offset = CGSize(width: offset.width + event.scrollingDeltaX * k, height: offset.height + event.scrollingDeltaY * k)
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
```

In `paneMenu`, use `menuPoint` instead of `hover`, evaluated before the `Task`:

```swift
        Menu("Aggiungi dispositivo") {
            ForEach(DeviceKind.allCases, id: \.self) { kind in
                Button {
                    let at = snap(toWorld(menuPoint))
                    Task { await editor.addDevice(kind, at: at) }
                } label: { Label(kind.label, systemImage: kind.symbol) }
            }
        }
        Button("Incolla") {
            let at = snap(toWorld(menuPoint))
            Task { await editor.paste(at: at) }
        }
```

(The old code read `hover` inside the `Task`, i.e. after the menu closed — by then hover can be the menu item's position.)

- [ ] **Step 3: CommitField ends editing on Return**

In `CommitField.body` replace `.onSubmit(submit)` with `.onSubmit { focused = false }` — the focus-loss handler commits once, and the window's first responder is no longer a text view, so Cmd+Z right after Return undoes the network change.

- [ ] **Step 4: One Editor per window**

Replace `MainView` in `Sources/PacTrack/PacTrackApp.swift`:

```swift
struct MainView: View {
    @Binding var document: PacDocument
    /// Built once, on appear: a `@State` initial value would allocate a throwaway Editor + Simulation on every view init.
    @State private var editor: Editor?

    var body: some View {
        if let editor {
            DocumentWindow(document: $document, editor: editor)
        } else {
            Theme.bg
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { editor = Editor(client: Simulation()) }
        }
    }
}

private struct DocumentWindow: View {
    @Binding var document: PacDocument
    let editor: Editor

    var body: some View {
        MainContent(editor: editor)
            .frame(minWidth: 1000, minHeight: 640)
            .toolbar { SimulationToolbar(editor: editor) }
            .focusedSceneValue(\.editor, editor)
            .preferredColorScheme(.dark)
            .task {
                // Only a successfully loaded document may be overwritten by later edits.
                if await editor.load(document.topology) {
                    editor.onChange = { document.topology = $0 }
                }
            }
            .task { await editor.runClock() }
    }
}
```

- [ ] **Step 5: Manual checklist**

Create `docs/manual-checks/m2b.md`:

```markdown
# M2b — manual checks

Build and open: `scripts/bundle.sh && open build/PacTrack.app`. Start from two PCs (10.0.0.1/24, 10.0.0.2/24) on a switch.

**Time modes**
- [ ] Toolbar ▸ *Simulation*: the clock stops and shows nanoseconds; *Passo* (or `.` with the canvas focused) runs one event: a row appears in *Eventi*, its PDU opens on the right, a coloured tag moves along the cable.
- [ ] In Simulation press ▶: events advance about twice a second at 1×, faster at higher speeds; ⏸ stops.
- [ ] Back to *Realtime*: the clock runs again; a ping shows ARP/ICMP tags flashing along the cables.

**Events and PDU**
- [ ] Toggle ARP/ICMP/UDP filters and pick a node: the list follows; the counter updates.
- [ ] Click an ICMP row: Ethernet II / IPv4 / ICMP headers with MACs, TTL, checksum, id/seq; groups collapse.
- [ ] Drag the divider between canvas and bottom panel, and between the list and the PDU inspector.
- [ ] Cmd+Z after a network change empties the event list (new network).

**Links and power**
- [ ] Select a cable: set Banda `10`, Ritardo `1000`, Perdita `50`, Coda `5`; the cable label shows `10 Mb/s`; ping shows losses and ~2 ms RTT. Type `abc`: red error under the field.
- [ ] Right-click a cable ▸ *Simula guasto*: dashed red; ping fails. ▸ *Ripristina*: ping works. Cmd+Z undoes each.
- [ ] Right-click PC1 ▸ *Spegni*: dimmed, red LED, Ping/Traceroute disabled; power button in the inspector turns it back on.
- [ ] Save, close, reopen: link values, faults and powered-off devices are as left.

**Copy, paste, palette**
- [ ] Select PC1, Cmd+C, Cmd+V twice: PC3, PC4 appear stepped below-right with PC1's IP; Cmd+D duplicates the selection. Right-click empty canvas ▸ *Incolla*: the copy lands under the pointer.
- [ ] In a text field Cmd+C/V/X/A edit text, not devices.
- [ ] Type `rou` in the palette search: only Router remains; `zzz` shows "Nessun dispositivo".

**Loop warning**
- [ ] Two switches with two cables between them, a PC pinging any address: an orange banner warns of a possible L2 loop on the switches; the app stays responsive; ✕ closes it.

**M2a fixes**
- [ ] Pinch zoom keeps the point under the fingers fixed; two-finger scroll pans the canvas (not the inspector or panels).
- [ ] Type an IP + Return, then Cmd+Z right away: the network change is undone (the field is no longer focused).
- [ ] Right-click empty canvas ▸ *Aggiungi dispositivo* ▸ Router: R1 appears under where you right-clicked, also when the menu item lies over the canvas.
```

- [ ] **Step 6: GREEN — everything**

Run: `scripts/selftest.sh build/selftest.png && scripts/test.sh 2>&1 | tail -1 && scripts/bundle.sh`
Expected: `SELFTEST OK`, 133 tests, `build/PacTrack.app`. Launch `build/PacTrack.app/Contents/MacOS/PacTrack` in the background for ~5 s, check it is still running and its log is empty, kill it. Read `build/selftest.png`.

- [ ] **Step 7: Commit**

```bash
git add Sources/PacTrack docs/manual-checks/m2b.md
git commit -m "fix(app): anchor pinch zoom, pan with two-finger scroll, freeze the menu insertion point, end editing on Return, one Editor per window"
```

---

## Done criteria for M2b

- `scripts/test.sh` green (133), `scripts/selftest.sh` prints `SELFTEST OK` and the PNG shows the Simulation clock, events with PDU inspector, a PDU on a cable, link properties, a powered-off device and a faulty cable; `scripts/bundle.sh` app launches cleanly.
- `docs/manual-checks/m2b.md` ready for the user.
- Deferred to later milestones by spec: Rinnova DHCP (M3), Metriche tab (M4), multi-selection actions, minimap, effective-speed indicator.
