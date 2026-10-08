# M6 — Polish, Cloud/ISP, packaging, README (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the MVP: every spec item still missing after M1–M5 (duplicate-address validation, effective speed, multiple selection and its menus, Sposta/Collega tools with the cable palette, grid toggle, minimap, switch sizes, ping options, PNG export), the Cloud/ISP device built from the existing router, NAT and DNS, an app icon in the ad-hoc signed bundle, an Italian README for v3, and v1 (`legacy/`) gone.

**Architecture:** `PacEngine` gains a segment walk for duplicate addresses (`Interface.segmentPeers`), `effectiveSpeed` in the `Snapshot`, `Switch.setPorts` (retired interfaces stay alive), a `Cloud` router subclass that owns every public address it has no route for, DNS replies from the address queried, ICMP errors about local packets from the address hit, and public `PingOptions` on `.ping`. `PacKit`'s `Editor` gets multiple selection (`Selection.nodes`, group copy/paste/duplicate), presentation state for the tool, cable kind and grid, the Cloud preset, typed ping options and `exportBounds`. `PacTrack` wires gestures, menus, toolbar, palette, minimap, File ▸ Esporta immagine… (`ImageRenderer`), and `scripts/bundle.sh` draws the icon with a small Swift script and `iconutil`.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM, `iconutil`/`codesign` from the Command Line Tools — no Xcode.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2: §11 item 6 "export immagini, icona e packaging `.app` firmato, rimozione v1 (`legacy/`), README"; §5.5 Cloud/ISP and switch sizes; §5.6 ping options; §6 effective speed; §7.1 ①②③, §7.2, §7.4; §8 PNG export with `ImageRenderer`; §9 "IP duplicato nello stesso segmento" — milestone M6, the last). Conventions: `docs/superpowers/plans/2026-10-08-m5-nat-firewall.md`; rulings ledger style: `.superpowers/sdd/2026-10-08-m5-nat-firewall/progress.md`.

## Global Constraints

- Run every `swift`/`swiftc`/`scripts/*.sh` command **outside the sandbox**; unit tests only via `scripts/test.sh` (bare `swift test` runs zero tests with CLT). End-to-end: `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`.
- Work in place on branch `rewrite/v3`; never switch branches or create worktrees. **Stage only the files a task lists** (`git add <paths>`). Never delete the untracked `NEXT_STEPS.md` or `electron-app/`.
- An M5 review fix pass may run concurrently: do not edit `L3/Nat.swift`, `L3/Firewall.swift`, `NatTests`, `FirewallTests`, `RuntimeNatFirewallTests`, `NatFirewallEditorTests`; in `IpNode.swift` touch only `setIp` and `icmpError`; in `Runtime.swift` only the spots a task names; in `ServicesTab.swift` only the doc comment, `body` and the new `internet` view; in `InspectorView.swift` never `tables`. M5 is used only through its public surface (`.setNat`, `Editor.setNatRole`).
- The UI never holds engine objects — only `Snapshot` values and string ids. Never store `SimTimer`s. Removed nodes **and removed interfaces** stay alive until the Sim is replaced (frames may still be on their cable).
- No new randomness; never iterate a `Dictionary` where order is observable.
- Every network change goes through `Editor.edit` (one undo step: a group paste, a group power change, a cable with its settings, a switch size). Selection, tool, cable kind and grid are presentation state: no undo, not saved.
- `.ptk`: `Topology.version` stays `1`; new `DeviceKind` value `"cloud"`; a switch's size is its saved interface count (8 in every older file).
- User-facing copy Italian; engine error messages English (as M2–M5); code, comments, tests, commits English. Colours only via `Theme`.
- Ponytail: every API below has a consumer in this plan; nothing outside the MVP (spec §3); no notarization, DMG or zip; deliberate shortcuts carry a `ponytail:` comment naming the ceiling.
- Commit trailer (exactly this line, after a blank line):
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

## Review Focus

1. **Typing V, C, Backspace, Cmd+A or Cmd+D in a text field** → the field gets the key (letter typed, character deleted, text selected, nothing duplicated); the canvas tools and menu actions fire only outside fields. Pinned: bare keys stay canvas `onKeyPress` handlers, menu actions forward to `NSText` when typing (Task 4, 5) and `docs/manual-checks/m6.md` (no XCUITest without Xcode).
2. **A file or an undo whose network holds one address twice** (a cable joined two segments) → it still opens; only typing a duplicate is refused. Pinned: `aDuplicateMadeByCablingStillOpensFromAFile` (Task 1).
3. **Pasting or duplicating several devices** → distinct default names, the group's shape kept, one undo step. Pinned: `copiesPastesAndDuplicatesADeviceWithItsConfiguration` (Task 3), `duplicatesPowersAndDeletesSeveralDevicesAsOneStepEach` (Task 3).
4. **Making a switch smaller right after pulling a cable with a frame on the wire** → no crash (the link's pending events still reach the removed port). Pinned: `shrinkingRightAfterUnpluggingWithAFrameOnTheWireKeepsRunning` (Task 6).
5. **The Cloud and addresses that are not the Internet** → a private address with no route is unreachable, an unused address of the cloud's own subnet is host-unreachable; only public unrouted addresses answer. Pinned: `tracerouteEndsAtTheProbedAddressAndPrivateOrLocalAddressesAreUnreachable` (Task 7).

## Spec audit (M1–M5 against the spec)

| Spec | Gap found (evidence) | Handled |
|---|---|---|
| §11-6, §8 PNG export | no `ImageRenderer`/`NSSavePanel` anywhere in `Sources/` | Task 10 |
| §11-6 icon, packaging | `scripts/bundle.sh` copies binary + plist only; no `CFBundleIconFile` | Task 11 |
| §11-6 v1 removal, README | `legacy/` tracked; `README.md` describes v1 (HTML/JS, `npm start`), `preview.png` is a v1 screenshot | Task 12 |
| §5.5 Cloud/ISP | `DeviceKind` has no cloud; user decision 2026-10-08: in M6 | Tasks 7–8 |
| §9 "IP duplicato nello stesso segmento" | `IpNode.setIp` checks network/broadcast and own overlaps only; M3 ledger: "no duplicate-IP warning existed" | Task 1 |
| §6 `clock.effectiveSpeed` | `Runtime.swift`: "spec §6 effective speed, not yet reported"; no `Snapshot` field | Task 2 |
| §7.1 ③, §7.2 multiple selection | `Selection` holds one node or link; M2b plan "Deferred … multi-selection actions, minimap" | Tasks 3–4 |
| §7.2 canvas *Seleziona tutto*, node *Mostra tabelle* | `CanvasView.paneMenu` has 3 items, `NodeMenu` no *Mostra tabelle* | Task 4 |
| M2b deferred minors (user-visible) | Edit ▸ *Elimina* lost with `CommandGroup(replacing: .pasteboard)`; Cmd+D duplicates while typing | Task 4 |
| §7.1 ① tool Sposta/Collega, §7.4 V/C | toolbar has mode/play/step/speed only; cables only from the handle | Task 5 |
| §7.1 ② cable palette | `PaletteView` lists devices only; every cable is 1 Gb/s | Task 5 |
| §7.2 *Griglia on/off*, §7.1 ① Vista menu | grid always drawn and snapped; no View-menu command | Task 5 |
| §7.1 ③ minimap, link "banda/ritardo" | no minimap; cable label shows bandwidth only | Task 5 |
| §5.5 switch 8/24/48 ports | `Switch(ports: 8)` fixed | Task 6 |
| §5.6 ping count/interval/size/TTL | engine `PingOptions` internal, `Command.ping` has none, App tab has none | Task 9 |
| §8 `view` key in `.ptk` | zoom/pan not saved | **not included** — saving it would mark the document edited on every pan; *Adatta alla vista* reframes in one click (user decision) |
| §6 log "configurabile" | `Sim(logCapacity:)` exists; the spec names no UI | not a gap |
| §8 top-level `services` | services saved per node | ruled in M3 |
| §7.4 V/C/Space/. as menu shortcuts | they are canvas keys | ruling below |
| §10 test scenarios | all present (`switchAgesOutMacEntriesAfter300Seconds`, `pingAcrossTwoRoutersSeesTtl62`, `aBulkTransferFillsA10MbLinkToTheTheoreticalGoodput`, `tailDropsWhenTheQueueIsFull`, `icmpEchoWith56BytesIs98BytesOnEthernetAnd122OnTheWire`, …) | none needed |

## Rulings (where the spec is silent)

Each line: ruling — why — cost if wrong.

- README in Italian — the spec is in Italian and silent on the README; the UI is Italian — an English reader needs a translation.
- Cloud/ISP is a `Router` subclass (4 ports, TTL 255, forwarding) that owns every public unicast address it has no route for: ping, traceroute's last hop, TCP RST and its DNS server answer from that address; private (RFC 1918, loopback, link-local, `0/8`) and multicast/reserved addresses are never "the Internet"; a default route on the cloud turns the Internet off — one override, no new subsystem — a lab wanting a real far-side server cables it to Gi0/1–3 with its own subnet.
- Cloud preset, applied by the editor in the creating undo step: Gi0/0 `203.0.113.1/24` (RFC 5737) and the DNS record `www.example.com → 198.51.100.10`; DNS answers on any public address (README and Servizi suggest `8.8.8.8`); DHCP allowed (as on routers), NAT and firewall not (spec: routers) — a working Internet out of the box — users of other address plans retype Gi0/0.
- A DNS server answers from the address it was asked (it was answering from the outgoing interface; resolvers drop replies from another address) — BIND/Unbound behaviour, needed by the Cloud — none.
- ICMP errors about a packet addressed to the node itself come from that address (Linux `icmp_send` for local routes), others from the way back as before — traceroute's last hop must show the probed address — none.
- Duplicate addresses: typing an address used by another interface in the same broadcast domain (across cables, switches and hubs, any power or link state) is refused; cabling that joins two segments is never refused, and files and undo still open because `load` sets addresses before cables — the spec lists it as a configuration error; a real cable cannot refuse — a duplicate made by cabling shows only as ARP confusion.
- Effective speed = the last Realtime tick's simulated advance over its target × speed; equal to the speed while paused, idle or in Simulation; the toolbar shows it only below 90 % — a storm visibly slows time — a single slow tick flashes the warning for 50 ms.
- Multiple selection: Shift-click toggles, Shift-drag on empty canvas draws a rectangle (a plain drag still pans), dragging a selected device moves the group; the group menu has exactly the spec's four items; copies never carry cables (as single copies) — spec §7.2 — cables between copied devices must be redrawn.
- One test owns the process-wide clipboard (`copiesPastesAndDuplicatesADeviceWithItsConfiguration`): Swift Testing runs suites in parallel — none.
- V, C, Space and `.` stay canvas `onKeyPress` keys, not menu key equivalents; Edit ▸ *Elimina* has no key equivalent (the canvas deletes on Backspace through `onDeleteCommand`) — a bare-key menu equivalent steals the letter from every text field — the shortcuts are not listed in the menus (toolbar help and README list them).
- Cables: *Ethernet 1 Gb/s* = the engine default (500 ns, ~100 m); *Fibra 10 Gb/s* = 10 Gb/s, 5 µs (1 km at 2×10⁸ m/s); *Personalizzato* = Ethernet defaults, then the new cable opens in the inspector; choosing a cable switches to *Collega* — Packet Tracer's flow — none.
- Grid off hides the dots and stops snapping; grid, tool and cable kind are per window and not saved — spec "griglia con snap" — reopened documents start with the grid on.
- Switch size is chosen in the Porte tab (8/24/48; only free ports can go) and saved as the interface count (a file listing another count opens with 8, as tests write abbreviated switches); removed ports are retired, not freed — spec §5.5 — a corrupt size opens silently as 8.
- Ping fields in the App tab: count, interval in seconds, payload bytes, TTL (blank: the device's 64/255); context-menu pings keep the defaults — spec §5.6 — none.
- PNG export: every device and cable at 2×, 40 pt margin, dark theme, selection and moving PDUs as on screen, File ▸ *Esporta immagine…* (Cmd+Shift+E), disabled on an empty canvas — spec §8 — none.
- Icon drawn at bundle time by `scripts/make-icon.swift` (compiled with `swiftc`) into an iconset, `iconutil` makes the `.icns`; no binary in git; signing stays ad-hoc (spec §4); no notarization (needs a Developer ID) — reproducible from source — a fresh clone needs ~5 s more per bundle.
- v1 removal: `legacy/` and `preview.png` (v1's screenshot) go; `CONTRIBUTING.md` (v1's JavaScript guide) and `.gitignore`'s Node sections are left for the user to decide — the spec names `legacy/` — a stale contributing guide until decided.

---

## File Structure

```
Sources/PacEngine/Node.swift                   Interface.segmentPeers(), Node.removeLastInterface() (retired list)
Sources/PacEngine/L3/IpNode.swift              setIp: duplicate address; icmpError: source for local packets
Sources/PacEngine/L3/Dns.swift                 DnsServer answers from the queried address
Sources/PacEngine/Devices/Router.swift         no longer final
Sources/PacEngine/Devices/Cloud.swift          (new) Cloud
Sources/PacEngine/Devices/Switch.swift         setPorts(_:)
Sources/PacEngine/Apps/Ping.swift              public PingOptions, readable option errors
Sources/PacEngine/Runtime/Protocol.swift       DeviceKind.cloud, .setPorts, .ping options, SWITCH_PORTS, Snapshot.effectiveSpeed
Sources/PacEngine/Runtime/Runtime.swift        effective speed, cloud, setPorts, ping options, DNS/DHCP on clouds, load order notes
Sources/PacKit/Topology+Helpers.swift          cloud label/prefix/tabs, defaultName(_:taken:), Tool, CableKind, exportBounds
Sources/PacKit/Editor.swift                    Selection.nodes, selectedNodes/select(nodes:)/toggle/selectAll, group copy/paste/duplicate,
                                               tool/cable/grid/aligned, cable options on connect, cloud preset, ping(_:…)
Sources/PacTrack/PacTrackApp.swift             tool picker, effective speed, Edit/View/File menu items
Sources/PacTrack/MainContent.swift             PaletteView(editor:)
Sources/PacTrack/PaletteView.swift             cables, cloud
Sources/PacTrack/CanvasView.swift              rectangle selection, grid toggle, minimap, V/C, delay label, export init
Sources/PacTrack/DeviceNodeView.swift          shift-click, group drag, Collega drag, group menu, Mostra tabelle
Sources/PacTrack/InspectorView.swift           multiple-selection text, switch size picker, ping fields
Sources/PacTrack/ServicesTab.swift             DNS/DHCP on clouds, Internet note
Sources/PacTrack/Controls.swift                "ports:" field errors
Sources/PacTrack/Theme.swift                   cloud symbol
Sources/PacTrack/ExportImage.swift             (new) PNG export
Sources/PacTrack/SelfTest.swift                M6 scenarios and images
Tests/PacEngineTests/{DuplicateAddressTests,EffectiveSpeedTests,SwitchPortsTests,CloudTests}.swift (new)
Tests/PacKitTests/{SelectionEditorTests,ToolsEditorTests,DeviceEditorTests,PingEditorTests}.swift (new)
Tests/PacKitTests/{EditorTests,ServicesEditorTests,HelpersTests}.swift
scripts/make-icon.swift (new), scripts/bundle.sh, Resources/Info.plist
README.md, docs/screenshot.png (new), legacy/ (removed), preview.png (removed)
docs/manual-checks/m6.md (new)
```

---

### Task 1: Engine — refuse an address already used on the same segment

**Files:**
- Modify: `Sources/PacEngine/Node.swift`, `Sources/PacEngine/L3/IpNode.swift` (only `setIp`), `Sources/PacEngine/Runtime/Runtime.swift` (only a comment in `load`)
- Create: `Tests/PacEngineTests/DuplicateAddressTests.swift`

**Interfaces:**
- Consumes: `Link.peer(_:)`, `Node.interfaces`, `IpNode`, `formatIp`, `Runtime.handle`, `expectError` (TestUtils), `Topology`, `TopologyNode`, `TopologyIface`, `LinkView`.
- Produces: `extension Interface { func segmentPeers() -> [Interface] }`; `IpNode.setIp` throws `EngineError("Duplicate address: <ip> is already used by <node name> <iface> on this segment")`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/DuplicateAddressTests.swift`:

```swift
import Testing
@testable import PacEngine

private func cable(_ rt: Runtime, _ id: String, _ a: String, _ ai: String, _ b: String, _ bi: String) throws {
    try rt.handle(.connect(id: id, a: IfaceRef(node: a, iface: ai), b: IfaceRef(node: b, iface: bi)))
}

/// PC1, PC2 and R1 Gi0/0 on SW1; PC3 on HUB1, which hangs off SW1; PC4 behind R1 Gi0/1.
private func lab() throws -> Runtime {
    let rt = Runtime()
    let devices: [(String, DeviceKind, String)] = [("a", .pc, "PC1"), ("b", .pc, "PC2"), ("c", .pc, "PC3"), ("d", .pc, "PC4"),
                                                   ("s", .switch, "SW1"), ("h", .hub, "HUB1"), ("r", .router, "R1")]
    for (id, kind, name) in devices { try rt.handle(.addNode(id: id, kind: kind, name: name)) }
    try cable(rt, "1", "a", "eth0", "s", "Gi0/1")
    try cable(rt, "2", "b", "eth0", "s", "Gi0/2")
    try cable(rt, "3", "h", "p1", "s", "Gi0/3")
    try cable(rt, "4", "c", "eth0", "h", "p2")
    try cable(rt, "5", "r", "Gi0/0", "s", "Gi0/4")
    try cable(rt, "6", "d", "eth0", "r", "Gi0/1")
    return rt
}

@Suite struct DuplicateAddressTests {
    @Test func anAddressInUseOnTheSameSegmentIsRefusedAcrossSwitchesAndHubs() throws {
        let rt = try lab()
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        expectError("Duplicate address: 10.0.0.1 is already used by PC1 eth0 on this segment") {
            try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.1/24"))
        }
        expectError("already used by PC1 eth0") { try rt.handle(.setIp(node: "c", iface: "eth0", cidr: "10.0.0.1/25")) } // through the hub
        expectError("already used by PC1 eth0") { try rt.handle(.setIp(node: "r", iface: "Gi0/0", cidr: "10.0.0.1/24")) }
        #expect(rt.snapshot().nodes[1].ifaces[0].cidr == nil) // nothing changed
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/16")) // its own address again
        try rt.handle(.setIp(node: "d", iface: "eth0", cidr: "10.0.0.1/24")) // behind R1: another segment
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.2/24"))
    }

    @Test func aDuplicateMadeByCablingStillOpensFromAFile() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "b", kind: .pc, name: "PC2"))
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.setIp(node: "b", iface: "eth0", cidr: "10.0.0.1/24")) // not cabled yet: another segment
        try cable(rt, "l1", "a", "eth0", "s", "Gi0/1")
        try cable(rt, "l2", "b", "eth0", "s", "Gi0/2") // a cable is never refused
        let origin = Pos(x: 0, y: 0)
        let pc = { (id: String, name: String) in
            TopologyNode(id: id, kind: .pc, name: name, pos: origin, ifaces: [TopologyIface(name: "eth0", cidr: "10.0.0.1/24")], routes: [])
        }
        let sw = TopologyNode(id: "s", kind: .switch, name: "SW1", pos: origin,
                              ifaces: (1...8).map { TopologyIface(name: "Gi0/\($0)", cidr: nil) }, routes: [])
        let links = [LinkView(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/1")),
                     LinkView(id: "l2", a: IfaceRef(node: "b", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2"))]
        try rt.handle(.load(Topology(nodes: [pc("a", "PC1"), pc("b", "PC2"), sw], links: links)))
        #expect(rt.snapshot().nodes.compactMap { $0.ifaces.first?.cidr } == ["10.0.0.1/24", "10.0.0.1/24"])
        #expect(rt.snapshot().links.count == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: `anAddressInUseOnTheSameSegmentIsRefusedAcrossSwitchesAndHubs` FAILS (no error thrown for PC2); the file test passes already (it pins behaviour Step 3 must keep).

- [ ] **Step 3: Implement**

`Sources/PacEngine/Node.swift` — after the `Interface` class add:

```swift
extension Interface {
    /// IP interfaces in this interface's broadcast domain: across cables, switches and hubs, whatever their power or link state; self excluded.
    func segmentPeers() -> [Interface] {
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
        var todo = [self]
        var peers: [Interface] = []
        while let i = todo.popLast() {
            guard let peer = i.link?.peer(i), seen.insert(ObjectIdentifier(peer)).inserted else { continue }
            if peer.node is IpNode {
                peers.append(peer)
            } else {
                for next in peer.node.interfaces where seen.insert(ObjectIdentifier(next)).inserted { todo.append(next) }
            }
        }
        return peers
    }
}
```

`Sources/PacEngine/L3/IpNode.swift` — in `setIp`, between the overlap loop and `iface.ipv4 = c` add:

```swift
        if let other = iface.segmentPeers().first(where: { $0.ipv4?.addr == c.addr }) {
            throw EngineError("Duplicate address: \(formatIp(c.addr)) is already used by \(other.node.name) \(other.name) on this segment")
        }
```

`Sources/PacEngine/Runtime/Runtime.swift` — in `load(_:)`, above `for n in t.nodes {` (the first loop) add the comment:

```swift
        // Addresses before cables: a duplicate made by cabling two segments together (never refused) still opens.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (2 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Node.swift Sources/PacEngine/L3/IpNode.swift Sources/PacEngine/Runtime/Runtime.swift Tests/PacEngineTests/DuplicateAddressTests.swift
git commit -m "feat(engine): refuse an address already used on the same segment, keep files with cabled duplicates opening

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Engine + toolbar — report the effective speed

**Files:**
- Modify: `Sources/PacEngine/Runtime/Protocol.swift` (only `Snapshot`), `Sources/PacEngine/Runtime/Runtime.swift` (the `MAX_EVENTS_PER_ADVANCE` comment, a property, `.setSpeed`, `advance`, `build`), `Sources/PacTrack/PacTrackApp.swift` (only `SimulationToolbar`), `Sources/PacTrack/SelfTest.swift` (only `loopScenario`)
- Create: `Tests/PacEngineTests/EffectiveSpeedTests.swift`

**Interfaces:**
- Consumes: `Runtime.advance(wallMs:)`, `run(until:maxEvents:)`, `MAX_EVENTS_PER_ADVANCE`, `MAX_STEP_MS`, `Theme.warn`.
- Produces: `Snapshot.effectiveSpeed: Double` (memberwise position: right after `speed`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/EffectiveSpeedTests.swift`:

```swift
import Testing
@testable import PacEngine

/// Two switches cabled twice and a PC asking ARP into them: a broadcast storm that uses up every tick's event budget.
private func storm() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "s1", kind: .switch, name: "SW1"))
    try rt.handle(.addNode(id: "s2", kind: .switch, name: "SW2"))
    try rt.handle(.connect(id: "x", a: IfaceRef(node: "s1", iface: "Gi0/1"), b: IfaceRef(node: "s2", iface: "Gi0/1")))
    try rt.handle(.connect(id: "y", a: IfaceRef(node: "s1", iface: "Gi0/2"), b: IfaceRef(node: "s2", iface: "Gi0/2")))
    try rt.handle(.connect(id: "z", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s1", iface: "Gi0/3")))
    try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
    try rt.handle(.ping(node: "a", target: "10.0.0.9"))
    return rt
}

@Suite struct EffectiveSpeedTests {
    @Test func aStormReportsTheSpeedActuallyReached() throws {
        let rt = try storm()
        for _ in 0..<3 { rt.advance(wallMs: 100) }
        let s = rt.snapshot()
        #expect(s.speed == 1 && s.effectiveSpeed < 1 && s.effectiveSpeed >= 0)
    }

    @Test func anIdleOrPausedClockKeepsTheChosenSpeed() throws {
        let idle = Runtime()
        try idle.handle(.setSpeed(5))
        idle.advance(wallMs: 50)
        #expect(idle.snapshot().effectiveSpeed == 5)
        let rt = try storm()
        for _ in 0..<3 { rt.advance(wallMs: 100) }
        try rt.handle(.setRunning(false))
        let paused = rt.snapshot()
        #expect(paused.effectiveSpeed == 1)
        rt.advance(wallMs: 100)
        #expect(rt.snapshot().version == paused.version) // nothing moves while paused
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build error — `Snapshot` has no member `effectiveSpeed`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Runtime/Protocol.swift` — in `Snapshot`, after `public let speed: Double` add:

```swift
    /// Speed the last Realtime tick actually reached; below `speed` when a tick ran out of its event budget (spec §6).
    public let effectiveSpeed: Double
```

and `Snapshot.empty` becomes:

```swift
    public static let empty = Snapshot(version: 0, seed: 1, timeNs: 0, running: true, speed: 1, effectiveSpeed: 1, mode: .realtime, epoch: 0,
                                       eventCount: 0, nodes: [], links: [], apps: [], warnings: [], linkSamples: [:])
```

`Sources/PacEngine/Runtime/Runtime.swift`:

The comment above `MAX_EVENTS_PER_ADVANCE` is rewritten (it said "not yet reported"):

```swift
/// ponytail: fixed work budget per clock tick; a storm slows simulated time instead of freezing the app (reported as Snapshot.effectiveSpeed)
```

After `private var stepCredit = 0.0` add:

```swift
    /// Speed reached by the last Realtime tick.
    private var effectiveSpeed = 1.0
```

`case let .setSpeed(value):` becomes:

```swift
        case let .setSpeed(value):
            guard value > 0 && value <= 1000 else { throw EngineError("Invalid speed: \(value)") }
            speed = value
            effectiveSpeed = value
```

In `advance(wallMs:)`, `case .realtime:` becomes:

```swift
        case .realtime:
            let start = sim.now
            let target = start + Int((min(wallMs, MAX_STEP_MS) * Double(MS) * speed).rounded())
            run(until: target, maxEvents: MAX_EVENTS_PER_ADVANCE)
            effectiveSpeed = target > start ? speed * Double(sim.now - start) / Double(target - start) : speed
```

In `build()`, the `Snapshot(…)` call gets `effectiveSpeed:` after `speed: speed,`:

```swift
        return Snapshot(version: 0, seed: seed, timeNs: now, running: running, speed: speed,
                        effectiveSpeed: running && mode == .realtime ? effectiveSpeed : speed, mode: mode, epoch: epoch,
                        eventCount: sim.log.total, nodes: nodeViews, links: linkViews, apps: appViews,
                        warnings: sim.warnings.map { WarningView(id: $0.id, node: $0.node, timeNs: $0.time) },
                        linkSamples: linkSamples.mapValues { Array($0.suffix(METRICS_HISTORY)) })
```

`Sources/PacTrack/PacTrackApp.swift` — in `SimulationToolbar`, after the clock `Text(…).frame(width: 150, alignment: .trailing)` add:

```swift
            if s.mode == .realtime && s.running && s.effectiveSpeed < s.speed * 0.9 {
                Text(String(format: "effettiva %.1f×", s.effectiveSpeed))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.warn)
                    .help("Troppi eventi per tick: la simulazione non tiene la velocità scelta.")
            }
```

`Sources/PacTrack/SelfTest.swift` — in `loopScenario()`, the last line `return editor.warning == nil ? ["no L2 loop warning"] : []` becomes:

```swift
        var failures = editor.warning == nil ? ["no L2 loop warning"] : []
        if editor.snapshot.effectiveSpeed >= editor.snapshot.speed { failures.append("the storm did not lower the effective speed") }
        return failures
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (2 more). Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Sources/PacTrack/PacTrackApp.swift Sources/PacTrack/SelfTest.swift Tests/PacEngineTests/EffectiveSpeedTests.swift
git commit -m "feat: report the effective speed when a tick runs out of budget and show it in the toolbar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: PacKit — multiple selection, group copy, paste and duplicate

**Files:**
- Modify: `Sources/PacKit/Editor.swift`, `Sources/PacKit/Topology+Helpers.swift` (only `defaultName`), `Tests/PacKitTests/EditorTests.swift` (only `copiesPastesAndDuplicatesADeviceWithItsConfiguration`), `Tests/PacKitTests/ServicesEditorTests.swift` (one call), and the callers that must keep compiling: `Sources/PacTrack/PacTrackApp.swift` (`EditCommands` Copia/Duplica), `Sources/PacTrack/DeviceNodeView.swift` (`NodeMenu` Duplica/Copia), `Sources/PacTrack/InspectorView.swift` (`InspectorView.body` switch), `Sources/PacTrack/SelfTest.swift` (one call)
- Create: `Tests/PacKitTests/SelectionEditorTests.swift`

**Interfaces:**
- Consumes: `Editor.current`, `editNow`, `serialized`, `remove(nodes:links:)`, `newId()`, `copyOffset`.
- Produces: `Selection.nodes([String])`; `Editor.selectedNodes: [String]`; `Editor.select(nodes: [String])`; `Editor.toggle(_ id: String)`; `Editor.selectAll()`; `Editor.copy(_ ids: [String])`; `Editor.duplicate(_ ids: [String]) async`; `Editor.paste(at:)` pastes the whole clipboard; `func defaultName(_ kind: DeviceKind, taken: Set<String>) -> String` (internal).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacKitTests/SelectionEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct SelectionEditorTests {
    let editor = Editor(client: Simulation())

    private var names: [String] { editor.snapshot.nodes.map(\.name) }
    private func id(_ name: String) -> String { editor.snapshot.nodes.first { $0.name == name }!.id }

    private func threePcs() async {
        for x in [0.0, 112, 224] { await editor.addDevice(.pc, at: Pos(x: x, y: 0)) }
    }

    @Test func shiftClicksBuildAMultipleSelectionAndSelectAllTakesEveryDevice() async {
        await threePcs()
        editor.select(.node(id("PC1")))
        editor.toggle(id("PC3"))
        #expect(editor.selection == .nodes([id("PC1"), id("PC3")]))
        #expect(editor.selectedNodes == [id("PC1"), id("PC3")])
        editor.toggle(id("PC1"))
        #expect(editor.selection == .node(id("PC3"))) // one left: an ordinary selection, the inspector shows it
        editor.toggle(id("PC3"))
        #expect(editor.selection == nil && editor.selectedNodes.isEmpty)
        editor.select(.link("x"))
        editor.toggle(id("PC2")) // a cable is not a device: shift-click starts over
        #expect(editor.selection == .node(id("PC2")))
        editor.selectAll()
        #expect(editor.selectedNodes == [id("PC1"), id("PC2"), id("PC3")])
        editor.select(nodes: [])
        #expect(editor.selection == nil)
    }

    @Test func duplicatesPowersAndDeletesSeveralDevicesAsOneStepEach() async {
        await threePcs()
        let pcs = [id("PC1"), id("PC3")]
        await editor.duplicate(pcs)
        #expect(names == ["PC1", "PC2", "PC3", "PC4", "PC5"]) // distinct names in one step
        #expect(editor.positions[id("PC4")] == Pos(x: 56, y: 56) && editor.positions[id("PC5")] == Pos(x: 280, y: 56))
        #expect(editor.selection == .nodes([id("PC4"), id("PC5")]))
        await editor.edit(editor.selectedNodes.map { .setPower(id: $0, on: false) })
        #expect(editor.snapshot.nodes.map(\.powered) == [true, true, true, false, false])
        editor.select(nodes: [id("PC4"), id("PC5")])
        await editor.deleteSelection()
        #expect(names == ["PC1", "PC2", "PC3"])
        await editor.undo()
        #expect(names == ["PC1", "PC2", "PC3", "PC4", "PC5"])
        await editor.undo()
        #expect(editor.snapshot.nodes.allSatisfy(\.powered))
        await editor.undo()
        #expect(names == ["PC1", "PC2", "PC3"])
    }
}
```

In `Tests/PacKitTests/EditorTests.swift`, `copiesPastesAndDuplicatesADeviceWithItsConfiguration` changes `editor.copy(pc)` to `editor.copy([pc])` and `await editor.duplicate(copy.id)` to `await editor.duplicate([copy.id])`, and gains, after its last `#expect(names == ["PC1"])`:

```swift
        // Several devices: one paste, distinct names, the group keeps its shape. This test alone uses the process-wide clipboard
        // (suites run in parallel).
        await editor.addDevice(.pc, at: Pos(x: 112, y: 14))
        editor.copy([pc, node("PC2").id])
        await editor.paste(at: Pos(x: 14, y: 140))
        #expect(names == ["PC1", "PC2", "PC3", "PC4"])
        #expect(editor.positions[node("PC3").id] == Pos(x: 14, y: 140) && editor.positions[node("PC4").id] == Pos(x: 112, y: 140))
        #expect(editor.selection == .nodes([node("PC3").id, node("PC4").id]))
        await editor.undo()
        #expect(names == ["PC1", "PC2"])
```

In `Tests/PacKitTests/ServicesEditorTests.swift`, `duplicatesKeepDhcpModeAndDnsServer`: `await editor.duplicate(pc)` → `await editor.duplicate([pc])`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `toggle`, `selectedNodes`, `select(nodes:)`, `selectAll`, `.nodes` unknown; `copy`/`duplicate` take a `String`.

- [ ] **Step 3: Implement**

`Sources/PacKit/Topology+Helpers.swift` — `defaultName` becomes:

```swift
public func defaultName(_ kind: DeviceKind, existing nodes: [NodeView]) -> String {
    defaultName(kind, taken: Set(nodes.map(\.name)))
}

/// Lowest free "<prefix><n>" given the names already used (several devices added in one step).
func defaultName(_ kind: DeviceKind, taken: Set<String>) -> String {
    var i = 1
    while taken.contains("\(kind.namePrefix)\(i)") { i += 1 }
    return "\(kind.namePrefix)\(i)"
}
```

`Sources/PacKit/Editor.swift`:

`Selection` becomes:

```swift
public enum Selection: Equatable, Sendable {
    case node(String)
    case link(String)
    /// Two or more devices, in the order they were picked.
    case nodes([String])
}
```

The clipboard becomes a list:

```swift
    /// Process-wide device clipboard.
    // ponytail: in-memory, not NSPasteboard; enough to copy between windows of this app
    private static var clipboard: [TopologyNode] = []
```

After `select(_:)` add:

```swift
    /// Devices in the selection, in the order they were picked; empty for a cable or nothing.
    public var selectedNodes: [String] {
        switch selection {
        case .node(let id): [id]
        case .nodes(let ids): ids
        case .link, nil: []
        }
    }

    /// Several devices at once (rectangle, Seleziona tutto): none clears, one is an ordinary selection.
    public func select(nodes ids: [String]) {
        selection = ids.count > 1 ? .nodes(ids) : ids.first.map { .node($0) }
    }

    /// Shift-click: adds the device to the selected ones or takes it out.
    public func toggle(_ id: String) {
        let ids = selectedNodes
        select(nodes: ids.contains(id) ? ids.filter { $0 != id } : ids + [id])
    }

    public func selectAll() {
        select(nodes: snapshot.nodes.map(\.id))
    }
```

`deleteSelection()` gains a case:

```swift
        case .nodes(let ids): await remove(nodes: ids, links: [])
```

`copy(_:)`, `paste(at:)`, `duplicate(_:)` and `insertCopy(of:)` are replaced by:

```swift
    public func copy(_ ids: [String]) {
        Self.clipboard = current.nodes.filter { ids.contains($0.id) }
    }

    /// Pastes the copied devices with the first one at `pos` (the group keeps its shape), or `copyOffset` below-right of the last copy.
    public func paste(at pos: Pos?) async {
        await serialized {
            guard let first = Self.clipboard.first else { return }
            let dx = pos.map { $0.x - first.pos.x } ?? Self.copyOffset
            let dy = pos.map { $0.y - first.pos.y } ?? Self.copyOffset
            let moved = Self.clipboard.map { n -> TopologyNode in
                var c = n
                c.pos = Pos(x: n.pos.x + dx, y: n.pos.y + dy)
                return c
            }
            if pos == nil { Self.clipboard = moved }
            await self.insertCopies(of: moved)
        }
    }

    public func duplicate(_ ids: [String]) async {
        await serialized {
            let srcs = self.current.nodes.filter { ids.contains($0.id) }.map { n -> TopologyNode in
                var c = n
                c.pos = Pos(x: n.pos.x + Self.copyOffset, y: n.pos.y + Self.copyOffset)
                return c
            }
            await self.insertCopies(of: srcs)
        }
    }

    /// Adds devices of the same kind, power state, interface modes and name server as `srcs` (no addresses, routes or cables: a copied IP
    /// would silently conflict on the same segment, and static routes need an address), with distinct default names, in one undo step,
    /// and selects them.
    private func insertCopies(of srcs: [TopologyNode]) async {
        guard !srcs.isEmpty else { return }
        var taken = Set(snapshot.nodes.map(\.name))
        var ids: [String] = []
        var cmds: [Command] = []
        for src in srcs {
            let id = newId()
            let name = defaultName(src.kind, taken: taken)
            taken.insert(name)
            ids.append(id)
            positions[id] = src.pos
            cmds.append(.addNode(id: id, kind: src.kind, name: name))
            // Modes and the name server are not addresses: a copied DHCP PC asks for its own lease.
            for i in src.ifaces where i.mode == .dhcp { cmds.append(.setIfaceMode(node: id, iface: i.name, mode: .dhcp)) }
            if let server = src.nameServer { cmds.append(.setNameServer(node: id, ip: server)) }
            if !src.powered { cmds.append(.setPower(id: id, on: false)) }
        }
        if await editNow(cmds, key: "paste") { select(nodes: ids) }
    }
```

Callers (single device for now; Task 4 turns them into group actions):
- `Sources/PacTrack/PacTrackApp.swift`, `EditCommands`: `editor?.copy(id)` → `editor?.copy([id])`; `editor?.duplicate(id)` → `editor?.duplicate([id])`.
- `Sources/PacTrack/DeviceNodeView.swift`, `NodeMenu`: `editor.duplicate(node.id)` → `editor.duplicate([node.id])`; `editor.copy(node.id)` → `editor.copy([node.id])`.
- `Sources/PacTrack/SelfTest.swift`: `await editor.duplicate(id("PC2"))` → `await editor.duplicate([id("PC2")])`.
- `Sources/PacTrack/InspectorView.swift`, `InspectorView.body`, after `case .link(let id): …` add:

```swift
            case .nodes(let ids):
                Text("\(ids.count) dispositivi selezionati. Trascinane uno per spostarli insieme; con il tasto destro: Duplica, Copia, Spegni/Accendi, Elimina.")
                    .foregroundStyle(Theme.muted)
                    .padding(12)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (2 more). Run: `swift build` → builds (the app compiles against the new API).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacKit/Editor.swift Sources/PacKit/Topology+Helpers.swift Sources/PacTrack/PacTrackApp.swift Sources/PacTrack/DeviceNodeView.swift Sources/PacTrack/InspectorView.swift Sources/PacTrack/SelfTest.swift Tests/PacKitTests/SelectionEditorTests.swift Tests/PacKitTests/EditorTests.swift Tests/PacKitTests/ServicesEditorTests.swift
git commit -m "feat(kit): select several devices, copy, paste and duplicate them as one step with distinct names

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: App — multiple selection gestures and menus, Seleziona tutto, Mostra tabelle, Edit menu fixes

**Files:**
- Modify: `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/DeviceNodeView.swift`, `Sources/PacTrack/PacTrackApp.swift` (only `EditCommands`), `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: Task 3 (`selectedNodes`, `select(nodes:)`, `toggle`, `selectAll`, `copy([String])`, `duplicate([String])`, `.nodes`), existing `remove(nodes:links:)`, `edit([Command])`, `deleteSelection()`, `inspectorTabs(for:)`, `InspectorTab.tables`, `SelfTest.render/sibling`.

- [ ] **Step 1: Baseline image**

Run: `scripts/selftest.sh build/m6-before.png` → `SELFTEST OK`; Read `build/m6-before.png`.

- [ ] **Step 2: Write the failing selftest scenario**

In `Sources/PacTrack/SelfTest.swift`, in `scenario(output:)` after `failures += await natScenario(output: output)` add `failures += await selectionScenario(output: output)` and add to `SelfTest`:

```swift
    /// M6: three devices, the first and the last picked together; Seleziona tutto takes all three.
    private static func selectionScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        for x in [420.0, 560, 700] { await editor.addDevice(.pc, at: Pos(x: x, y: 300)) }
        let ids = editor.snapshot.nodes.map(\.id)
        editor.select(.node(ids[0]))
        editor.toggle(ids[2])
        if editor.selection != .nodes([ids[0], ids[2]]) { failures.append("shift-click selection \(String(describing: editor.selection))") }
        if !render(editor, to: sibling(output, "m6-selection")) { failures.append("could not write the M6 selection image") }
        editor.selectAll()
        if editor.selectedNodes != ids { failures.append("select all \(editor.selectedNodes)") }
        return failures
    }
```

- [ ] **Step 3: Run it to verify the editor checks pass but the image lacks the UI**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; Read `build/selftest-m6-selection.png`: the inspector already reads "2 dispositivi selezionati. …" (Task 3) but no device is outlined (the node view still compares `selection == .node`) — the RED for this UI task is visual, as in M3–M5.

- [ ] **Step 4: Implement**

`Sources/PacTrack/DeviceNodeView.swift`:

Add `import AppKit` at the top. `@State private var dragStart: Pos?` becomes `@State private var dragStart: [String: Pos]?`. In `body`, `let selected = editor.selection == .node(node.id)` becomes `let selected = editor.selectedNodes.contains(node.id)`, and `.onTapGesture { editor.select(.node(node.id)) }` becomes:

```swift
        .onTapGesture {
            // Shift-click adds the device to the selection or takes it out (spec §7.1 ③).
            if NSEvent.modifierFlags.contains(.shift) { editor.toggle(node.id) } else { editor.select(.node(node.id)) }
        }
```

`drag` becomes:

```swift
    /// Moves the device, or every selected device when it is one of them, on the grid; one undo step per drag.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if dragStart == nil {
                    if !editor.selectedNodes.contains(node.id) { editor.select(.node(node.id)) }
                    dragStart = Dictionary(uniqueKeysWithValues: editor.selectedNodes.map { ($0, editor.positions[$0] ?? Pos(x: 0, y: 0)) })
                    editor.moveStart()
                }
                for (id, start) in dragStart ?? [:] {
                    editor.setPosition(id, snap(Pos(x: start.x + value.translation.width / zoom, y: start.y + value.translation.height / zoom)))
                }
            }
            .onEnded { _ in
                dragStart = nil
                editor.moveEnd()
            }
    }
```

`NodeMenu.body` becomes:

```swift
    var body: some View {
        let group = editor.selectedNodes
        if group.count > 1 && group.contains(node.id) {
            groupMenu(group)
        } else {
            single
        }
    }

    /// Spec §7.2: only what makes sense for several devices at once.
    @ViewBuilder
    private func groupMenu(_ ids: [String]) -> some View {
        let anyOn = editor.snapshot.nodes.contains { ids.contains($0.id) && $0.powered }
        Button("Duplica") { Task { await editor.duplicate(ids) } }
        Button("Copia") { editor.copy(ids) }
        Button(anyOn ? "Spegni" : "Accendi") { Task { await editor.edit(ids.map { .setPower(id: $0, on: !anyOn) }) } }
        Divider()
        Button("Elimina", role: .destructive) { Task { await editor.remove(nodes: ids, links: []) } }
    }

    /// One device (spec §7.2): the previous menu plus *Mostra tabelle*.
    @ViewBuilder
    private var single: some View {
        Button("Apri ispettore") { editor.select(.node(node.id)) }
        if inspectorTabs(for: node.kind).contains(.tables) {
            Button("Mostra tabelle") {
                editor.select(.node(node.id))
                editor.inspectorTab = .tables
            }
        }
        if node.kind.hasIp {
            let targets = Self.targets(for: node.id, in: editor.snapshot.nodes)
            Menu("Ping verso") {
                ForEach(targets) { t in
                    Button("\(t.name)  \(firstIp(t) ?? "")") { Task { await editor.run(.ping(node: node.id, target: firstIp(t) ?? ""), key: "app:\(node.id)") } }
                }
            }
            .disabled(targets.isEmpty || !node.powered)
            Menu("Traceroute verso") {
                ForEach(targets) { t in
                    Button("\(t.name)  \(firstIp(t) ?? "")") { Task { await editor.run(.traceroute(node: node.id, target: firstIp(t) ?? ""), key: "app:\(node.id)") } }
                }
            }
            .disabled(targets.isEmpty || !node.powered)
            if node.kind.isHost {
                Button("Rinnova DHCP") { Task { await editor.run(.renewDhcp(node: node.id), key: "app:\(node.id)") } }
                    .disabled(!node.powered || !node.ifaces.contains { $0.mode == .dhcp })
            }
        }
        Button(node.powered ? "Spegni" : "Accendi") { Task { await editor.edit(.setPower(id: node.id, on: !node.powered)) } }
        Divider()
        Button("Duplica") { Task { await editor.duplicate([node.id]) } }
        Button("Copia") { editor.copy([node.id]) }
        Divider()
        Button("Elimina", role: .destructive) { Task { await editor.remove(nodes: [node.id], links: []) } }
    }
```

`Sources/PacTrack/CanvasView.swift`:

After `@State private var hover = CGPoint.zero` add:

```swift
    /// Shift-drag selection rectangle, in canvas coordinates.
    @State private var band: CGRect?
```

In the `ZStack`, after the `if let wire { … }` block add:

```swift
                if let band {
                    Path(band).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).allowsHitTesting(false)
                }
```

In `background`, the `.gesture(DragGesture(minimumDistance: 3) …)` becomes:

```swift
        .gesture(
            // Shift-drag draws a selection rectangle; a plain drag pans.
            DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if band == nil, panStart == nil, NSEvent.modifierFlags.contains(.shift) { band = .zero }
                    if band != nil {
                        band = CGRect(origin: value.startLocation, size: .zero).union(CGRect(origin: value.location, size: .zero))
                        return
                    }
                    let start = panStart ?? offset
                    panStart = start
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in
                    if let rect = band { editor.select(nodes: editor.snapshot.nodes.filter { rect.contains(center($0.id)) }.map(\.id)) }
                    band = nil
                    panStart = nil
                }
        )
```

In `paneMenu(size:)`, before `Button("Adatta alla vista")` add `Button("Seleziona tutto") { editor.selectAll() }`.

`Sources/PacTrack/PacTrackApp.swift`, `EditCommands`: remove the now unused `selectedNode` property, and the `CommandGroup(replacing: .pasteboard)` becomes:

```swift
        // Text fields keep the standard editing actions; elsewhere the shortcuts act on devices.
        CommandGroup(replacing: .pasteboard) {
            Button("Taglia") { if typing { send("cut:") } }
                .keyboardShortcut("x")
            Button("Copia") {
                if typing { send("copy:") } else if let ids = editor?.selectedNodes, !ids.isEmpty { editor?.copy(ids) }
            }
            .keyboardShortcut("c")
            Button("Incolla") {
                if typing { send("paste:") } else { Task { await editor?.paste(at: nil) } }
            }
            .keyboardShortcut("v")
            // Never while typing: Cmd+D in a field must not duplicate the selected devices.
            Button("Duplica") {
                if !typing, let ids = editor?.selectedNodes, !ids.isEmpty { Task { await editor?.duplicate(ids) } }
            }
            .keyboardShortcut("d")
            // No key equivalent: Backspace stays with text fields; the canvas deletes on its own (onDeleteCommand).
            Button("Elimina") {
                if typing { send("delete:") } else { Task { await editor?.deleteSelection() } }
            }
            Button("Seleziona tutto") { if typing { send("selectAll:") } else { editor?.selectAll() } }
                .keyboardShortcut("a")
        }
```

- [ ] **Step 5: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m6-selection.png`: PC1 and PC3 outlined in the accent colour, PC2 not; the inspector reads "2 dispositivi selezionati. …". `scripts/test.sh 2>&1 | tail -3` stays green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PacTrack/CanvasView.swift Sources/PacTrack/DeviceNodeView.swift Sources/PacTrack/PacTrackApp.swift Sources/PacTrack/SelfTest.swift
git commit -m "feat(app): shift-click and rectangle selection, group drag and menu, Seleziona tutto, Mostra tabelle, Edit Elimina, no Cmd+D while typing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Sposta/Collega tools, cable palette, grid toggle, minimap, delay on cables

**Files:**
- Modify: `Sources/PacKit/Topology+Helpers.swift`, `Sources/PacKit/Editor.swift`, `Sources/PacTrack/PacTrackApp.swift`, `Sources/PacTrack/MainContent.swift`, `Sources/PacTrack/PaletteView.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/DeviceNodeView.swift`, `Sources/PacTrack/SelfTest.swift`
- Create: `Tests/PacKitTests/ToolsEditorTests.swift`

**Interfaces:**
- Consumes: `LinkOptions(bandwidthBps:propDelayNs:)`, `.connect`, `.updateLink`, `snap(_:grid:)`, `firstFreeIface`, Task 4's `drag`.
- Produces: `public enum Tool: String, CaseIterable, Sendable { move = "Sposta", connect = "Collega" }`; `public enum CableKind: String, CaseIterable, Sendable { ethernet = "Ethernet 1 Gb/s", fiber = "Fibra 10 Gb/s", custom = "Personalizzato"; var options: LinkOptions }`; `Editor.tool`, `Editor.cable`, `Editor.grid` (public vars); `Editor.aligned(_ p: Pos) -> Pos`; `PaletteView(editor:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacKitTests/ToolsEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct ToolsEditorTests {
    let editor = Editor(client: Simulation())

    @Test func paletteCablesSetTheLinkInOneStepAndCustomOpensItsProperties() async {
        #expect(CableKind.allCases.map(\.rawValue) == ["Ethernet 1 Gb/s", "Fibra 10 Gb/s", "Personalizzato"])
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 112, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 224, y: 0))
        let ids = editor.snapshot.nodes.map(\.id)
        editor.cable = .fiber
        await editor.connect(ids[0], ids[1])
        #expect(editor.snapshot.links[0].options == LinkOptions(bandwidthBps: 10e9, propDelayNs: 5_000))
        await editor.undo()
        #expect(editor.snapshot.links.isEmpty) // the cable and its settings: one step
        editor.cable = .custom
        await editor.connect(ids[0], ids[2])
        #expect(editor.snapshot.links[0].options == LinkOptions())
        #expect(editor.selection == .link(editor.snapshot.links[0].id)) // opens in the inspector
        editor.cable = .ethernet
        await editor.connect(ids[0], ids[1])
        #expect(editor.snapshot.links[1].options == LinkOptions() && editor.selection == .link(editor.snapshot.links[0].id))
    }

    @Test func theGridSnapsOnlyWhileShown() {
        #expect(editor.aligned(Pos(x: 20, y: 6)) == Pos(x: 14, y: 0))
        editor.grid = false
        #expect(editor.aligned(Pos(x: 20, y: 6)) == Pos(x: 20, y: 6))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `CableKind`, `cable`, `grid`, `aligned` unknown.

- [ ] **Step 3: Implement the kit**

`Sources/PacKit/Topology+Helpers.swift` — after `enum TrafficKind { … }` add:

```swift
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
```

`Sources/PacKit/Editor.swift` — after `public var bottomTab = BottomTab.events` add:

```swift
    /// Canvas tool and the cable it draws (palette); per window, not saved.
    public var tool = Tool.move
    public var cable = CableKind.ethernet
    /// Grid shown and snapped to (spec §7.2 "Griglia on/off").
    public var grid = true
```

After `setPosition(_:_:)` add:

```swift
    /// Where a device dropped or dragged at `p` lands: on the grid while it is shown.
    public func aligned(_ p: Pos) -> Pos {
        grid ? snap(p) : p
    }
```

`connectNow(_:_:)` ends (replacing its last line `await editNow([.connect(…)], key: "connect")`) with:

```swift
        let id = newId()
        let options = cable.options
        // Ethernet is the engine's default cable; another kind sets its link in the same undo step.
        let cmds: [Command] = [.connect(id: id, a: IfaceRef(node: aId, iface: ia), b: IfaceRef(node: bId, iface: ib))]
            + (options == LinkOptions() ? [] : [.updateLink(id: id, options: options)])
        // Personalizzato: the new cable opens in the inspector for its values.
        if await editNow(cmds, key: "connect"), cable == .custom { selection = .link(id) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (2 more).

- [ ] **Step 5: Baseline the UI and add the selftest scenario (visual RED)**

In `SelfTest.scenario(output:)` after `failures += await selectionScenario(output: output)` add `failures += await toolsScenario(output: output)`, and add:

```swift
    /// M6: a fibre cable drawn with the Collega tool, the grid hidden, the minimap in the corner.
    private static func toolsScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 420, y: 200))
        await editor.addDevice(.server, at: Pos(x: 700, y: 360))
        editor.tool = .connect
        editor.cable = .fiber
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        if editor.snapshot.links.first?.options.bandwidthBps != 10e9 { failures.append("fibre cable \(String(describing: editor.snapshot.links.first))") }
        editor.grid = false
        if !render(editor, to: sibling(output, "m6-tools")) { failures.append("could not write the M6 tools image") }
        return failures
    }
```

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; Read `build/selftest-m6-tools.png`: grid dots still drawn, no CAVI section, no minimap, the cable label without delay.

- [ ] **Step 6: Implement the UI**

`Sources/PacTrack/MainContent.swift`: `PaletteView().frame(width: 170)` → `PaletteView(editor: editor).frame(width: 170)`.

`Sources/PacTrack/PaletteView.swift` — add `@Bindable var editor: Editor` as the first property of `PaletteView`. In `body`, after the `ForEach(groups, …) { … }` block and before `Spacer()` add:

```swift
            let q = query.trimmingCharacters(in: .whitespaces)
            let cables = CableKind.allCases.filter { q.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(q) || "cavi".localizedCaseInsensitiveContains(q) }
            if !cables.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAVI").font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
                    ForEach(cables, id: \.self) { cable in
                        let on = editor.tool == .connect && editor.cable == cable
                        Label(cable.rawValue, systemImage: cable == .fiber ? "fibrechannel" : cable == .custom ? "slider.horizontal.3" : "cable.connector")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accent.opacity(0.35) : Color.clear))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editor.cable = cable
                                editor.tool = .connect
                            }
                            .accessibilityIdentifier("cable-\(cable)")
                    }
                }
            }
```

and the hint text becomes `"Trascina un dispositivo sul canvas. Per collegare, trascina dal pallino in basso, oppure scegli un cavo e trascina da un dispositivo all'altro."`.

`Sources/PacTrack/PacTrackApp.swift`:

In `SimulationToolbar`, inside `ToolbarItemGroup(placement: .navigation)`, after the redo button add:

```swift
            Picker("Strumento", selection: $editor.tool) {
                Label(Tool.move.rawValue, systemImage: "cursorarrow").tag(Tool.move)
                Label(Tool.connect.rawValue, systemImage: "cable.connector").tag(Tool.connect)
            }
            .pickerStyle(.segmented)
            .help("Sposta (V): trascini i dispositivi. Collega (C): trascini un cavo da un dispositivo all'altro.")
```

In `EditCommands.body`, after the pasteboard group add:

```swift
        CommandGroup(before: .toolbar) {
            Button(editor?.grid == false ? "Mostra griglia" : "Nascondi griglia") { editor?.grid.toggle() }
                .disabled(editor == nil)
            Divider()
        }
```

`Sources/PacTrack/DeviceNodeView.swift` — `drag` becomes (Task 4's group move plus the Collega tool and the grid toggle):

```swift
    /// Sposta: moves the device, or every selected device when it is one of them, one undo step per drag.
    /// Collega: draws a cable from the device to the one under the pointer.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if editor.tool == .connect {
                    wire = Wire(from: node.id, to: value.location)
                    return
                }
                if dragStart == nil {
                    if !editor.selectedNodes.contains(node.id) { editor.select(.node(node.id)) }
                    dragStart = Dictionary(uniqueKeysWithValues: editor.selectedNodes.map { ($0, editor.positions[$0] ?? Pos(x: 0, y: 0)) })
                    editor.moveStart()
                }
                for (id, start) in dragStart ?? [:] {
                    editor.setPosition(id, editor.aligned(Pos(x: start.x + value.translation.width / zoom, y: start.y + value.translation.height / zoom)))
                }
            }
            .onEnded { value in
                if editor.tool == .connect {
                    wire = nil
                    if let target = nodeAt(value.location), target != node.id { Task { await editor.connect(node.id, target) } }
                    return
                }
                dragStart = nil
                editor.moveEnd()
            }
    }
```

`Sources/PacTrack/CanvasView.swift`:

- `background` starts with `let showGrid = editor.grid` and `return Canvas { … }` (a computed property with two statements needs the explicit `return`); inside the Canvas closure `guard step >= 6 else { return }` becomes `guard showGrid, step >= 6 else { return }`.
- In `.dropDestination`, `snap(toWorld(location))` → `editor.aligned(toWorld(location))`; in `paneMenu`, both `snap(toWorld(menuPoint))` → `editor.aligned(toWorld(menuPoint))`.
- In `paneMenu`, after `Button("Adatta alla vista") { fit(size) }` add `Button(editor.grid ? "Nascondi griglia" : "Mostra griglia") { editor.grid.toggle() }`.
- In `cable(_:)`, the label becomes `Text("\(link.a.iface) ↔ \(link.b.iface) · \(formatBandwidth(link.options.bandwidthBps)) · \(LinkField.delay.format(link.options)) µs")`.
- After `.onKeyPress(KeyEquivalent(".")) { … }` add:

```swift
            .onKeyPress(KeyEquivalent("v")) {
                editor.tool = .move
                return .handled
            }
            .onKeyPress(KeyEquivalent("c")) {
                editor.tool = .connect
                return .handled
            }
```

- On the `ZStack`, after `.clipped()`, add:

```swift
            .overlay(alignment: .bottomTrailing) {
                if !editor.snapshot.nodes.isEmpty { minimap(geo.size) }
            }
```

- Add to `CanvasView` (in `// MARK: layers`):

```swift
    /// Overview (spec §7.1 ③): every device as a dot, the visible area as a frame; a click centres the view there.
    private func minimap(_ size: CGSize) -> some View {
        let box = CGSize(width: 160, height: 100)
        let visible = CGRect(x: -offset.width / zoom, y: -offset.height / zoom, width: size.width / zoom, height: size.height / zoom)
        let points = editor.snapshot.nodes.compactMap { editor.positions[$0.id] }.map { CGPoint(x: $0.x, y: $0.y) }
        let world = points.reduce(visible) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -40, dy: -40)
        let k = min(box.width / world.width, box.height / world.height)
        let map = { (p: CGPoint) in CGPoint(x: (p.x - world.minX) * k, y: (p.y - world.minY) * k) }
        return Canvas { ctx, _ in
            for p in points {
                ctx.fill(Path(ellipseIn: CGRect(origin: map(p), size: .zero).insetBy(dx: -2, dy: -2)), with: .color(Theme.fg))
            }
            let o = map(visible.origin)
            ctx.stroke(Path(CGRect(x: o.x, y: o.y, width: visible.width * k, height: visible.height * k)), with: .color(Theme.accent), lineWidth: 1)
        }
        .frame(width: box.width, height: box.height)
        .background(Theme.panel.opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in
            let c = CGPoint(x: p.x / k + world.minX, y: p.y / k + world.minY)
            offset = CGSize(width: size.width / 2 - c.x * zoom, height: size.height / 2 - c.y * zoom)
        }
        .padding(10)
        .accessibilityIdentifier("minimap")
    }
```

- [ ] **Step 7: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m6-tools.png`: no grid dots; palette CAVI with *Fibra 10 Gb/s* highlighted; the cable reads `Gi0/1 ↔ eth0 · 10 Gb/s · 5 µs`; the minimap bottom-right with two dots and the visible-area frame. Read `build/selftest.png`: grid dots present, cable labels end in `· 0.5 µs`. If the CAVI rows push the palette's hint off the 860 pt image, shorten the hint to one line and re-check. `scripts/test.sh` stays green.

- [ ] **Step 8: Commit**

```bash
git add Sources/PacKit/Topology+Helpers.swift Sources/PacKit/Editor.swift Sources/PacTrack/PacTrackApp.swift Sources/PacTrack/MainContent.swift Sources/PacTrack/PaletteView.swift Sources/PacTrack/CanvasView.swift Sources/PacTrack/DeviceNodeView.swift Sources/PacTrack/SelfTest.swift Tests/PacKitTests/ToolsEditorTests.swift
git commit -m "feat: Sposta/Collega tools with V and C, cable palette, grid on/off, minimap, delay on cable labels

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Switch sizes 8/24/48

**Files:**
- Modify: `Sources/PacEngine/Node.swift`, `Sources/PacEngine/Devices/Switch.swift`, `Sources/PacEngine/Runtime/Protocol.swift` (`Command`, `SWITCH_PORTS`), `Sources/PacEngine/Runtime/Runtime.swift` (`.setPorts` case, the first loop of `load`), `Sources/PacKit/Editor.swift` (`insertCopies`), `Sources/PacTrack/InspectorView.swift` (`ports`), `Sources/PacTrack/Controls.swift` (`ErrorBanner.fieldPrefixes`), `Sources/PacTrack/SelfTest.swift`
- Create: `Tests/PacEngineTests/SwitchPortsTests.swift`, `Tests/PacKitTests/DeviceEditorTests.swift`

**Interfaces:**
- Consumes: `Node.addInterface`, `Switch.table`, `Runtime.get`, Task 3's `insertCopies`, `duplicate([String])`.
- Produces: `Command.setPorts(id: String, count: Int)` (key `"setPorts"`); `public let SWITCH_PORTS = [8, 24, 48]`; `Switch.setPorts(_:) throws`; `Node.removeLastInterface()`; field error key `"ports:<node>"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/SwitchPortsTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct SwitchPortsTests {
    @Test func aSwitchGrowsTo24And48PortsAndShrinksOnlyOverFreePorts() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.setPorts(id: "s", count: 24))
        #expect(rt.snapshot().nodes[0].ifaces.map(\.name).last == "Gi0/24")
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/20")))
        expectError("Gi0/20 is connected") { try rt.handle(.setPorts(id: "s", count: 8)) }
        #expect(rt.snapshot().nodes[0].ifaces.count == 24)
        expectError("A switch has 8, 24 or 48 ports") { try rt.handle(.setPorts(id: "s", count: 12)) }
        expectError("PC1 cannot change its ports") { try rt.handle(.setPorts(id: "a", count: 24)) }
        try rt.handle(.setPorts(id: "s", count: 48))
        #expect(rt.snapshot().nodes[0].ifaces.count == 48)
    }

    @Test func shrinkingRightAfterUnpluggingWithAFrameOnTheWireKeepsRunning() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.setPorts(id: "s", count: 24))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/20")))
        try rt.handle(.updateLink(id: "l", options: LinkOptions(bandwidthBps: 1000))) // a 64 B ARP frame takes ~0.7 s to send
        try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.ping(node: "a", target: "10.0.0.2"))
        rt.advance(wallMs: 10)
        try rt.handle(.disconnect(id: "l"))
        try rt.handle(.setPorts(id: "s", count: 8)) // Gi0/20 goes while the link still has a frame to finish
        for _ in 0..<30 { rt.advance(wallMs: 100) }
        #expect(rt.snapshot().nodes[0].ifaces.count == 8)
    }

    @Test func aSavedSizeComesBackOnLoad() throws {
        let rt = Runtime()
        let sw = TopologyNode(id: "s", kind: .switch, name: "SW1", pos: Pos(x: 0, y: 0),
                              ifaces: (1...24).map { TopologyIface(name: "Gi0/\($0)", cidr: nil) }, routes: [])
        try rt.handle(.load(Topology(nodes: [sw])))
        #expect(rt.snapshot().nodes[0].ifaces.count == 24)
    }
}
```

Create `Tests/PacKitTests/DeviceEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct DeviceEditorTests {
    let editor = Editor(client: Simulation())

    @Test func aSwitchSizeIsOneUndoStepAndCopiesKeepIt() async {
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        let sw = editor.snapshot.nodes[0].id
        await editor.edit(.setPorts(id: sw, count: 24), key: "ports:\(sw)")
        #expect(editor.snapshot.nodes[0].ifaces.count == 24 && editor.current.nodes[0].ifaces.count == 24)
        await editor.duplicate([sw])
        #expect(editor.snapshot.nodes.map(\.ifaces.count) == [24, 24])
        await editor.undo()
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.ifaces.count) == [8])
        await editor.edit(.setPorts(id: sw, count: 12), key: "ports:\(sw)")
        #expect(editor.error == EditorError(key: "ports:\(sw)", message: "A switch has 8, 24 or 48 ports"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build error — `Command` has no member `setPorts`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Node.swift` — in `Node`, after `private(set) var interfaces: [Interface] = []` add:

```swift
    /// Interfaces taken away (a smaller switch): kept alive while a frame that was on their cable finishes (links refer to them `unowned`).
    // ponytail: never freed before the Sim is replaced; at most 40 per resize
    private var retired: [Interface] = []
```

and after `addInterface(_:)` add:

```swift
    func removeLastInterface() {
        retired.append(interfaces.removeLast())
    }
```

`Sources/PacEngine/Devices/Switch.swift` — after `init` add:

```swift
    /// 8, 24 or 48 ports (spec §5.5); the ports taken away must be free.
    func setPorts(_ count: Int) throws {
        guard SWITCH_PORTS.contains(count) else { throw EngineError("A switch has 8, 24 or 48 ports") }
        if let busy = interfaces.dropFirst(count).first(where: { $0.link != nil }) { throw EngineError("\(busy.name) is connected") }
        while interfaces.count > count { removeLastInterface() }
        while interfaces.count < count { addInterface("Gi0/\(interfaces.count + 1)") }
        table = table.filter { entry in interfaces.contains { $0 === entry.value.iface } }
    }
```

`Sources/PacEngine/Runtime/Protocol.swift` — in `Command`, after `case setPower(id: String, on: Bool)` add:

```swift
    /// Switch size: 8, 24 or 48 ports; only free ports can go.
    case setPorts(id: String, count: Int)
```

in `key`, after `case .setPower: "setPower"` add `case .setPorts: "setPorts"`; after `public let SPEEDS …` add:

```swift
/// Switch sizes offered in the Porte tab (spec §5.5).
public let SWITCH_PORTS = [8, 24, 48]
```

`Sources/PacEngine/Runtime/Runtime.swift` — after the `.setPower` case add:

```swift
        case let .setPorts(id, count):
            let node = try get(id)
            guard let sw = node as? Switch else { throw EngineError("\(node.name) cannot change its ports") }
            try sw.setPorts(count)
```

and in `load(_:)`'s first loop, after `try next.handle(.addNode(id: n.id, kind: n.kind, name: n.name))` add:

```swift
            // The saved size is the interface count; a file listing no valid size (hand-written, abbreviated) keeps 8.
            if n.kind == .switch, SWITCH_PORTS.contains(n.ifaces.count) { try next.handle(.setPorts(id: n.id, count: n.ifaces.count)) }
```

`Sources/PacKit/Editor.swift` — in `insertCopies(of:)`, after `cmds.append(.addNode(id: id, kind: src.kind, name: name))` add:

```swift
            if src.kind == .switch { cmds.append(.setPorts(id: id, count: src.ifaces.count)) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (4 more). Without `retired`, the in-flight test crashes the test process on an `unowned` reference — that is the bug it pins.

- [ ] **Step 5: UI — the size picker, with a selftest image**

In `SelfTest.scenario(output:)` after `failures += await toolsScenario(output: output)` add `failures += await portsScenario(output: output)` and:

```swift
    /// M6: a 24-port switch in its Porte tab.
    private static func portsScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 300))
        let sw = editor.snapshot.nodes[0].id
        await editor.edit(.setPorts(id: sw, count: 24), key: "ports:\(sw)")
        if editor.snapshot.nodes[0].ifaces.last?.name != "Gi0/24" { failures.append("switch ports \(editor.snapshot.nodes[0].ifaces.count)") }
        editor.select(.node(sw))
        if !render(editor, to: sibling(output, "m6-ports")) { failures.append("could not write the M6 ports image") }
        return failures
    }
```

`Sources/PacTrack/InspectorView.swift` — `ports` becomes:

```swift
    private var ports: some View {
        VStack(alignment: .leading, spacing: 2) {
            if node.kind == .switch {
                let key = "ports:\(node.id)"
                Picker("Porte", selection: Binding(get: { node.ifaces.count }, set: { n in
                    Task { await editor.edit(.setPorts(id: node.id, count: n), key: key) }
                })) {
                    ForEach(SWITCH_PORTS, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .accessibilityIdentifier("switch-ports")
                ErrorLine(editor: editor, key: key)
            }
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
```

`Sources/PacTrack/Controls.swift` — `ErrorBanner.fieldPrefixes` gains `"ports:"`.

- [ ] **Step 6: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; Read `build/selftest-m6-ports.png`: Porte tab with the 8 | 24 | 48 picker on 24 and ports down to Gi0/24 (scrolling). `scripts/test.sh` stays green.

- [ ] **Step 7: Commit**

```bash
git add Sources/PacEngine/Node.swift Sources/PacEngine/Devices/Switch.swift Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Sources/PacKit/Editor.swift Sources/PacTrack/InspectorView.swift Sources/PacTrack/Controls.swift Sources/PacTrack/SelfTest.swift Tests/PacEngineTests/SwitchPortsTests.swift Tests/PacKitTests/DeviceEditorTests.swift
git commit -m "feat: 8, 24 or 48 switch ports in the Porte tab, saved and copied, removed ports kept alive

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Engine — the Cloud/ISP device

**Files:**
- Modify: `Sources/PacEngine/Devices/Router.swift`, `Sources/PacEngine/L3/Dns.swift` (only `DnsServer`), `Sources/PacEngine/L3/IpNode.swift` (only `icmpError`), `Sources/PacEngine/Runtime/Protocol.swift` (`DeviceKind`), `Sources/PacEngine/Runtime/Runtime.swift` (`.setDnsServer` guard, `setDhcpServer` guard, `create`), and the exhaustive switches that must keep compiling: `Sources/PacKit/Topology+Helpers.swift` (`label`, `namePrefix`, `inspectorTabs`), `Sources/PacTrack/Theme.swift` (`symbol`)
- Create: `Sources/PacEngine/Devices/Cloud.swift`, `Tests/PacEngineTests/CloudTests.swift`

**Interfaces:**
- Consumes: `Router(sim:id:ports:)`, `IpNode.ownsIp`, `routes.lookup`, `inSubnet`, `sendPacket(_:_:ttl:src:)`, `makeUdp`, `.setNat`, `.setNameServer`, `.nslookup`, `.traceroute`.
- Produces: `DeviceKind.cloud` (raw value `"cloud"`, label "Cloud/ISP", name prefix "ISP", symbol "cloud", inspector tabs as a router's); `final class Cloud: Router`; DNS on servers and clouds; DHCP on routers, servers and clouds.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/CloudTests.swift`:

```swift
import Testing
@testable import PacEngine

private func run(_ rt: Runtime, seconds: Int) {
    for _ in 0..<(seconds * 10) { rt.advance(wallMs: 100) }
}

/// PC1 (192.168.1.10/24, DNS 8.8.8.8) — R1 (Gi0/0 192.168.1.1/24 inside, Gi0/1 203.0.113.2/24 outside, default via 203.0.113.1)
/// — ISP1 (Gi0/0 203.0.113.1/24, DNS www.example.com → 198.51.100.10).
private func cloudLab() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "pc", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r1", kind: .router, name: "R1"))
    try rt.handle(.addNode(id: "isp", kind: .cloud, name: "ISP1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "pc", iface: "eth0"), b: IfaceRef(node: "r1", iface: "Gi0/0")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "r1", iface: "Gi0/1"), b: IfaceRef(node: "isp", iface: "Gi0/0")))
    for (node, iface, cidr) in [("pc", "eth0", "192.168.1.10/24"), ("r1", "Gi0/0", "192.168.1.1/24"), ("r1", "Gi0/1", "203.0.113.2/24"),
                                ("isp", "Gi0/0", "203.0.113.1/24")] {
        try rt.handle(.setIp(node: node, iface: iface, cidr: cidr))
    }
    try rt.handle(.addRoute(node: "pc", cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
    try rt.handle(.addRoute(node: "r1", cidr: "0.0.0.0/0", nextHop: "203.0.113.1"))
    try rt.handle(.setNat(node: "r1", config: NatConfig(inside: ["Gi0/0"], outside: "Gi0/1")))
    try rt.handle(.setDnsServer(node: "isp", records: [DnsRecord(name: "www.example.com", ip: "198.51.100.10")]))
    try rt.handle(.setNameServer(node: "pc", ip: "8.8.8.8"))
    return rt
}

@Suite struct CloudTests {
    @Test func theInternetAnswersPingAndDnsFromAnyPublicAddress() throws {
        let rt = try cloudLab()
        #expect(rt.snapshot().nodes[2].kind == .cloud && rt.snapshot().nodes[2].ifaces.count == 4)
        try rt.handle(.ping(node: "pc", target: "8.8.8.8"))
        try rt.handle(.nslookup(node: "pc", name: "www.example.com"))
        run(rt, seconds: 6)
        try rt.handle(.ping(node: "pc", target: "www.example.com"))
        run(rt, seconds: 6)
        let apps = rt.snapshot().apps
        #expect(apps[0].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(apps[0].lines.contains { $0.hasPrefix("64 bytes from 8.8.8.8: icmp_seq=1 ttl=254") })
        #expect(apps[1].lines.contains("Address: 198.51.100.10")) // the answer came from 8.8.8.8, the address asked
        #expect(apps[2].lines.first == "PING www.example.com (198.51.100.10) 56(84) bytes of data.")
        #expect(apps[2].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
    }

    @Test func tracerouteEndsAtTheProbedAddressAndPrivateOrLocalAddressesAreUnreachable() throws {
        let rt = try cloudLab()
        try rt.handle(.traceroute(node: "pc", target: "198.51.100.10"))
        try rt.handle(.ping(node: "pc", target: "10.9.9.9"))
        try rt.handle(.ping(node: "pc", target: "203.0.113.99"))
        run(rt, seconds: 15)
        let apps = rt.snapshot().apps
        #expect(apps[0].done)
        #expect(apps[0].lines[1].hasPrefix(" 1  192.168.1.1 (192.168.1.1)"))
        #expect(apps[0].lines[2].hasPrefix(" 2  198.51.100.10 (198.51.100.10)")) // the port unreachable comes from the address probed
        #expect(apps[1].lines.contains { $0.hasPrefix("From 203.0.113.1 icmp_seq=1 Destination Net Unreachable") }) // private: no route
        #expect(apps[2].lines.contains { $0.hasPrefix("From 203.0.113.1 icmp_seq=1 Destination Host Unreachable") }) // its own subnet
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build error — `DeviceKind` has no member `cloud`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Runtime/Protocol.swift`:

```swift
/// `cloud`: an ISP edge router whose "Internet" answers by itself (spec §5.5).
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case pc, laptop, server, router, `switch`, hub, cloud
}
```

`Sources/PacEngine/Devices/Router.swift`: `final class Router: IpNode {` → `class Router: IpNode {`.

Create `Sources/PacEngine/Devices/Cloud.swift`:

```swift
/// Never "the Internet": this network, private (RFC 1918), loopback, link-local, multicast and reserved addresses.
private let NOT_INTERNET: [(net: UInt32, prefix: Int)] = [(0x0000_0000, 8), (0x0A00_0000, 8), (0x7F00_0000, 8), (0xA9FE_0000, 16),
                                                          (0xAC10_0000, 12), (0xC0A8_0000, 16), (0xE000_0000, 3)]

/// ISP edge (spec §5.5): a router whose Internet is every public address it has no route for. It answers for them itself —
/// ping, traceroute's last hop, TCP RST and the DNS server it runs — so a lab reaches "the Internet" through NAT with no more devices.
final class Cloud: Router {
    override func ownsIp(_ ip: UInt32) -> Bool {
        super.ownsIp(ip) || (!NOT_INTERNET.contains { inSubnet(ip, $0.net, $0.prefix) } && routes.lookup(ip) == nil)
    }
}
```

`Sources/PacEngine/L3/Dns.swift` — in `DnsServer`, the `bindUdp` handler and `answer` become:

```swift
        unbind = try node.bindUdp(PORT_DNS) { [weak self] p, u, _ in
            if case .dns(let m) = u.payload { self?.answer(m, to: p.src, from: p.dst, port: u.srcPort) }
        }
```

```swift
    /// Answers from the address it was asked (a resolver drops replies from any other), like BIND.
    private func answer(_ q: DnsMessage, to client: UInt32, from server: UInt32, port: UInt16) {
        guard !q.response else { return }
        let hits = records.filter { $0.name == q.name.lowercased() }
        let reply = DnsMessage(id: q.id, response: true, authoritative: true, recursionDesired: q.recursionDesired,
                               rcode: hits.isEmpty ? DNS_NXDOMAIN : 0, name: q.name,
                               answers: hits.map { DnsAnswer(ttl: UInt32($0.ttl), addr: $0.addr) })
        node.sendPacket(client, .udp(makeUdp(srcPort: PORT_DNS, dstPort: port, payload: .dns(reply))), src: server)
    }
```

`Sources/PacEngine/L3/IpNode.swift` — in `icmpError`, `guard let src = sourceFor(orig.src) else { return }` becomes:

```swift
        // About a packet for this node: from the address it hit (Linux; traceroute's last hop); otherwise from the way back.
        guard let src = ownsIp(orig.dst) ? orig.dst : sourceFor(orig.src) else { return }
```

`Sources/PacEngine/Runtime/Runtime.swift`:
- `case let .setDnsServer(node, records):` — the guard becomes `guard records == nil || nodes[node]?.kind == .server || nodes[node]?.kind == .cloud else { throw EngineError("\(n.name) cannot run a DNS server") }`.
- `setDhcpServer(_:_:requireInSubnet:)` — the guard becomes `guard config == nil || nodes[id]?.kind == .router || nodes[id]?.kind == .server || nodes[id]?.kind == .cloud else {`.
- `create(_:_:)` gains `case .cloud: Cloud(sim: sim, id: id)`.

`Sources/PacKit/Topology+Helpers.swift`: `label` gains `case .cloud: "Cloud/ISP"`; `namePrefix` gains `case .cloud: "ISP"`; `inspectorTabs` — `case .router, .server: […]` becomes `case .router, .server, .cloud: [.interfaces, .routing, .services, .tables, .app]`.

`Sources/PacTrack/Theme.swift` — `symbol` gains `case .cloud: "cloud"`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (2 more; no older test changes — none probes a router's far address or a multi-homed DNS server). Run: `swift build` → builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Devices/Router.swift Sources/PacEngine/Devices/Cloud.swift Sources/PacEngine/L3/Dns.swift Sources/PacEngine/L3/IpNode.swift Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Sources/PacKit/Topology+Helpers.swift Sources/PacTrack/Theme.swift Tests/PacEngineTests/CloudTests.swift
git commit -m "feat(engine): add the Cloud/ISP router whose Internet answers ping and DNS; DNS replies from the queried address

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Kit + app — Cloud/ISP preset, palette, Servizi

**Files:**
- Modify: `Sources/PacKit/Editor.swift` (`addDeviceNow`, `enableDhcp`), `Sources/PacTrack/PaletteView.swift` (`all`), `Sources/PacTrack/ServicesTab.swift` (doc comment, `body`, new `internet`), `Sources/PacTrack/SelfTest.swift`, `Tests/PacKitTests/DeviceEditorTests.swift`

**Interfaces:**
- Consumes: Task 7 (`DeviceKind.cloud`, DNS/DHCP on clouds), existing `editNow`, `setNatRole`, `DnsRecord`, `inspectorTabs`, `SelfTest.render/sibling`.

- [ ] **Step 1: Write the failing test**

Append to `DeviceEditorTests` in `Tests/PacKitTests/DeviceEditorTests.swift`:

```swift
    @Test func aCloudArrivesPreconfiguredInOneStepAndSurvivesSaving() async {
        await editor.addDevice(.cloud, at: Pos(x: 0, y: 0))
        let isp = editor.snapshot.nodes[0]
        #expect(isp.name == "ISP1" && isp.kind == .cloud)
        #expect(isp.ifaces.map(\.name) == ["Gi0/0", "Gi0/1", "Gi0/2", "Gi0/3"] && isp.ifaces[0].cidr == "203.0.113.1/24")
        #expect(isp.dnsRecords == [DnsRecord(name: "www.example.com", ip: "198.51.100.10")])
        #expect(inspectorTabs(for: .cloud) == [.interfaces, .routing, .services, .tables, .app])
        let saved = editor.current
        await editor.undo()
        #expect(editor.snapshot.nodes.isEmpty) // one step
        let opened = await editor.load(saved)
        #expect(opened && editor.snapshot.nodes[0].kind == .cloud && editor.snapshot.nodes[0].dnsRecords?.count == 1)
        await editor.enableDhcp(editor.snapshot.nodes[0].id, true)
        #expect(editor.snapshot.nodes[0].dhcpServer?.gateway == "203.0.113.1") // the cloud routes: it is the gateway
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: `aCloudArrivesPreconfiguredInOneStepAndSurvivesSaving` FAILS (no address on Gi0/0, no DNS records).

- [ ] **Step 3: Implement the kit**

`Sources/PacKit/Editor.swift` — `addDeviceNow(_:at:)` becomes:

```swift
    private func addDeviceNow(_ kind: DeviceKind, at pos: Pos) async {
        let id = newId()
        positions[id] = pos
        var cmds: [Command] = [.addNode(id: id, kind: kind, name: defaultName(kind, existing: snapshot.nodes))]
        // A Cloud/ISP arrives ready (spec §5.5): the provider end of a customer link (RFC 5737) and a public name to resolve.
        if kind == .cloud {
            cmds += [.setIp(node: id, iface: "Gi0/0", cidr: "203.0.113.1/24"),
                     .setDnsServer(node: id, records: [DnsRecord(name: "www.example.com", ip: "198.51.100.10")])]
        }
        if await editNow(cmds) {
            selection = .node(id)
        }
    }
```

In `enableDhcp(_:_:)`, `config.gateway = node.kind == .router ? own : gatewayOf(node)` becomes `config.gateway = node.kind == .router || node.kind == .cloud ? own : gatewayOf(node)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (1 more).

- [ ] **Step 5: Selftest scenario (visual RED)**

In `SelfTest.scenario(output:)` after `failures += await portsScenario(output: output)` add `failures += await cloudScenario(output: output)` and:

```swift
    /// M6: PC1 behind R1's NAT reaches ISP1's Internet: ping by name through its public DNS.
    private static func cloudScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.router, at: Pos(x: 560, y: 300))
        await editor.addDevice(.cloud, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("PC1"), id("R1")) // PC1 eth0 — R1 Gi0/0
        await editor.connect(id("R1"), id("ISP1")) // R1 Gi0/1 — ISP1 Gi0/0 (203.0.113.1/24, preset)
        for (name, iface, cidr) in [("PC1", "eth0", "192.168.1.10/24"), ("R1", "Gi0/0", "192.168.1.1/24"), ("R1", "Gi0/1", "203.0.113.2/24")] {
            await editor.edit(.setIp(node: id(name), iface: iface, cidr: cidr))
        }
        await editor.edit(.addRoute(node: id("PC1"), cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
        await editor.edit(.addRoute(node: id("R1"), cidr: "0.0.0.0/0", nextHop: "203.0.113.1"))
        await editor.setNatRole(id("R1"), iface: "Gi0/0", .inside)
        await editor.setNatRole(id("R1"), iface: "Gi0/1", .outside)
        await editor.edit(.setNameServer(node: id("PC1"), ip: "8.8.8.8"))
        await editor.run(.ping(node: id("PC1"), target: "www.example.com"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if lines.first?.hasPrefix("PING www.example.com (198.51.100.10)") != true || !lines.contains("4 packets transmitted, 4 received, 0% packet loss") {
            failures.append("ping to the Internet \(lines)")
        }
        editor.select(.node(id("ISP1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m6-cloud")) { failures.append("could not write the M6 cloud image") }
        return failures
    }
```

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; Read `build/selftest-m6-cloud.png`: ISP1's Servizi shows only the DHCP toggle (no DNS records, no Internet note); the palette has no Cloud/ISP.

- [ ] **Step 6: Implement the UI**

`Sources/PacTrack/PaletteView.swift` — `all` becomes `[("Rete", [.router, .switch, .hub, .cloud]), ("Host", [.pc, .laptop, .server])]`.

`Sources/PacTrack/ServicesTab.swift` — the doc comment becomes `/// DHCP server (routers, servers, clouds), DNS server (servers, clouds), sink (servers), NAT and firewall (routers): settings plus live tables (spec §7.1 ④).`; `body` becomes:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if node.kind == .cloud { internet }
            dhcp
            if node.kind == .server || node.kind == .cloud { dns }
            if node.kind == .server { sink }
            if node.kind == .router {
                nat
                firewall
            }
        }
    }

    private var internet: some View {
        Text("Internet simulata: \(node.name) risponde da sé a ogni indirizzo pubblico per cui non ha una route (ping, traceroute) e su ognuno fa da DNS pubblico, per esempio 8.8.8.8. Collega a Gi0/0 il router del cliente: 203.0.113.x/24, gateway 203.0.113.1.")
            .font(Theme.small)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
```

- [ ] **Step 7: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m6-cloud.png`: ISP1 with the cloud symbol and `203.0.113.1`; Servizi shows the Internet note, the DHCP toggle and the DNS server with `www.example.com  198.51.100.10  TTL 3600s`; Output shows the ping to `www.example.com (198.51.100.10)` with 4 received; Rete in the palette lists Cloud/ISP. `scripts/test.sh` stays green.

- [ ] **Step 8: Commit**

```bash
git add Sources/PacKit/Editor.swift Sources/PacTrack/PaletteView.swift Sources/PacTrack/ServicesTab.swift Sources/PacTrack/SelfTest.swift Tests/PacKitTests/DeviceEditorTests.swift
git commit -m "feat: Cloud/ISP in the palette, preconfigured with 203.0.113.1 and a public DNS name, Internet note in Servizi

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Ping count, interval, size and TTL

**Files:**
- Modify: `Sources/PacEngine/Apps/Ping.swift` (`PingOptions`, the option guard), `Sources/PacEngine/Runtime/Protocol.swift` (`.ping`), `Sources/PacEngine/Runtime/Runtime.swift` (`.ping` case), `Sources/PacKit/Editor.swift`, `Sources/PacTrack/InspectorView.swift` (`AppTab`), `Sources/PacTrack/SelfTest.swift`
- Create: `Tests/PacKitTests/PingEditorTests.swift`

**Interfaces:**
- Consumes: `Ping(node:target:options:)`, `Editor.fail`, `runNow`, `serialized`.
- Produces: `public struct PingOptions: Equatable, Sendable { count, intervalNs, timeoutNs, size, ttl; public init(count: Int = 4, intervalNs: Int = 1_000_000_000, timeoutNs: Int = 10_000_000_000, size: Int = 56, ttl: Int? = nil) }`; `case ping(node: String, target: String, options: PingOptions = PingOptions())`; option errors `"Invalid ping option: <what>"`; `Editor.ping(_:target:count:interval:size:ttl:) async`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PacKitTests/PingEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct PingEditorTests {
    let editor = Editor(client: Simulation())

    @Test func pingTakesCountIntervalSizeAndTtlFromTypedFields() async {
        await editor.addDevice(.pc, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 112, y: 0))
        let (a, b) = (editor.snapshot.nodes[0].id, editor.snapshot.nodes[1].id)
        await editor.connect(a, b)
        await editor.edit(.setIp(node: a, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: b, iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.ping(a, target: "10.0.0.2", count: "2", interval: "0,2", size: "1472", ttl: "")
        for _ in 0..<10 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        #expect(lines.first == "PING 10.0.0.2 (10.0.0.2) 1472(1500) bytes of data.")
        #expect(lines.filter { $0.hasPrefix("1480 bytes from 10.0.0.2") }.count == 2)
        #expect(lines.contains("2 packets transmitted, 2 received, 0% packet loss"))
        await editor.ping(a, target: "10.0.0.2", count: "due", interval: "1", size: "56", ttl: "")
        #expect(editor.error == EditorError(key: "app:\(a)", message: "Invalid number: \"due\""))
        await editor.ping(a, target: "10.0.0.2", count: "1", interval: "1", size: "56", ttl: "0")
        #expect(editor.error == EditorError(key: "app:\(a)", message: "Invalid ping option: TTL must be between 1 and 255"))
        #expect(editor.snapshot.apps.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build error — `Editor` has no member `ping`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Apps/Ping.swift` — `PingOptions` becomes:

```swift
/// iputils options (spec §5.6): -c count, -i interval, -W timeout, -s size, -t ttl (nil: the node's default).
public struct PingOptions: Equatable, Sendable {
    public var count: Int
    public var intervalNs: Int
    /// How long to wait after the last request before giving up.
    public var timeoutNs: Int
    public var size: Int
    public var ttl: Int?

    public init(count: Int = 4, intervalNs: Int = 1_000_000_000, timeoutNs: Int = 10_000_000_000, size: Int = 56, ttl: Int? = nil) {
        self.count = count
        self.intervalNs = intervalNs
        self.timeoutNs = timeoutNs
        self.size = size
        self.ttl = ttl
    }
}
```

and in `init(node:target:options:)`, the `// Upper bounds keep …` comment and the `guard … else { throw EngineError("Invalid ping option: \(options)") }` under it (after `let o = options`) become:

```swift
        // Upper bounds keep timer arithmetic far from overflow and the timer list small.
        let problem: String? =
            !(1...10_000).contains(o.count) ? "count must be between 1 and 10000"
            : !(1...3600 * S).contains(o.intervalNs) ? "interval must be above 0 and at most 3600 s"
            : !(1...3600 * S).contains(o.timeoutNs) ? "timeout must be above 0 and at most 3600 s"
            : !(0...65507).contains(o.size) ? "size must be between 0 and 65507 bytes"
            : o.ttl.map({ !(1...255).contains($0) }) ?? false ? "TTL must be between 1 and 255"
            : nil
        if let problem { throw EngineError("Invalid ping option: \(problem)") }
```

(`PingTests.rejectsInvalidOptionsSynchronously` keeps passing: it matches the "Invalid ping option" fragment.)

`Sources/PacEngine/Runtime/Protocol.swift` — `case ping(node: String, target: String)` becomes:

```swift
    case ping(node: String, target: String, options: PingOptions = PingOptions())
```

`Sources/PacEngine/Runtime/Runtime.swift` — the `.ping` case becomes:

```swift
        case let .ping(node, target, options):
            let t = target.trimmingCharacters(in: .whitespaces)
            start(node, "ping \(t)", .ping(try Ping(node: try liveIpNode(node), target: t, options: options)))
```

`Sources/PacKit/Editor.swift` — before `startTraffic(_:target:kind:amount:seconds:)` add:

```swift
    /// The App tab's ping (spec §5.6): count, interval in seconds, payload bytes, TTL (blank: the device's default). Errors show under the App tab.
    public func ping(_ id: String, target: String, count: String, interval: String, size: String, ttl: String) async {
        await serialized {
            let key = "app:\(id)"
            let text = { (s: String) in s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".") }
            guard let c = Int(text(count)) else { return self.fail(key, EngineError("Invalid number: \"\(count)\"")) }
            guard let i = Double(text(interval)), i.isFinite, abs(i) < 1e6 else { return self.fail(key, EngineError("Invalid number: \"\(interval)\"")) }
            guard let s = Int(text(size)) else { return self.fail(key, EngineError("Invalid number: \"\(size)\"")) }
            let t = text(ttl)
            guard t.isEmpty || Int(t) != nil else { return self.fail(key, EngineError("Invalid number: \"\(ttl)\"")) }
            let options = PingOptions(count: c, intervalNs: Int((i * 1e9).rounded()), size: s, ttl: Int(t))
            _ = await self.runNow(.ping(node: id, target: target, options: options), key: key)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (1 more).

- [ ] **Step 5: Selftest scenario (visual RED)**

In `SelfTest.scenario(output:)` after `failures += await cloudScenario(output: output)` add `failures += await pingScenario(output: output)` and:

```swift
    /// M6: ping with count, interval, size and TTL typed in the App tab.
    private static func pingScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.pc, at: Pos(x: 460, y: 300))
        await editor.addDevice(.pc, at: Pos(x: 660, y: 300))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        await editor.edit(.setIp(node: ids[0], iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: ids[1], iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.ping(ids[0], target: "10.0.0.2", count: "3", interval: "0.5", size: "1472", ttl: "1")
        for _ in 0..<20 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if lines.first != "PING 10.0.0.2 (10.0.0.2) 1472(1500) bytes of data." || !lines.contains("3 packets transmitted, 3 received, 0% packet loss") {
            failures.append("ping options \(lines)")
        }
        editor.select(.node(ids[0]))
        editor.inspectorTab = .app
        editor.bottomTab = .output
        if !render(editor, to: sibling(output, "m6-ping")) { failures.append("could not write the M6 ping image") }
        return failures
    }
```

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; Read `build/selftest-m6-ping.png`: the App tab has no ping fields.

- [ ] **Step 6: Implement the UI**

`Sources/PacTrack/InspectorView.swift`, `AppTab`: after `@State private var seconds = "10"` add:

```swift
    @State private var count = "4"
    @State private var interval = "1"
    @State private var size = "56"
    @State private var ttl = ""
```

after the `TextField("10.0.2 o nome host", …)` line add:

```swift
            HStack(spacing: 6) {
                field("Pacchetti", $count)
                field("Intervallo s", $interval)
                field("Byte", $size)
                field("TTL", $ttl, placeholder: "auto")
            }
```

the Ping button becomes:

```swift
                Button("Ping") {
                    Task { await editor.ping(node.id, target: target, count: count, interval: interval, size: size, ttl: ttl) }
                }
```

and add to `AppTab`:

```swift
    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(Theme.mono)
        }
    }
```

- [ ] **Step 7: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m6-ping.png`: four labelled fields (4, 1, 56, `auto`) under Destinazione, all inside the 300 pt inspector; Output shows `PING 10.0.0.2 (10.0.0.2) 1472(1500) bytes of data.` and three 1480-byte replies. If a label is cut, split the row into two `HStack`s of two and re-check. `scripts/test.sh` stays green.

- [ ] **Step 8: Commit**

```bash
git add Sources/PacEngine/Apps/Ping.swift Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Sources/PacKit/Editor.swift Sources/PacTrack/InspectorView.swift Sources/PacTrack/SelfTest.swift Tests/PacKitTests/PingEditorTests.swift
git commit -m "feat: ping count, interval, size and TTL from the App tab, readable option errors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: File ▸ Esporta immagine… (PNG with ImageRenderer)

**Files:**
- Modify: `Sources/PacKit/Topology+Helpers.swift`, `Sources/PacTrack/CanvasView.swift` (an `init`, the monitor `onAppear`, the minimap overlay), `Sources/PacTrack/PacTrackApp.swift` (`EditCommands`), `Sources/PacTrack/SelfTest.swift`, `Tests/PacKitTests/HelpersTests.swift`
- Create: `Sources/PacTrack/ExportImage.swift`

**Interfaces:**
- Consumes: `CanvasView.nodeSize`, `Editor.positions`, `Theme`.
- Produces: `public func exportBounds(_ centers: [Pos], nodeSize: CGSize, margin: Double) -> CGRect?`; `CanvasView.init(editor: Editor, exportOffset: CGSize? = nil)`; `ExportImage.png(_ editor: Editor) -> Data?`, `ExportImage.save(_ editor: Editor)`.

- [ ] **Step 1: Write the failing test**

Add `import CoreGraphics` at the top of `Tests/PacKitTests/HelpersTests.swift` and append to `HelpersTests`:

```swift
    @Test func exportFramesEveryDeviceBoxWithAMargin() {
        #expect(exportBounds([], nodeSize: CGSize(width: 104, height: 46), margin: 40) == nil)
        let r = exportBounds([Pos(x: 100, y: 100), Pos(x: 300, y: 200)], nodeSize: CGSize(width: 104, height: 46), margin: 40)
        #expect(r == CGRect(x: 8, y: 37, width: 384, height: 226))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build error — `exportBounds` unknown.

- [ ] **Step 3: Implement the kit helper**

`Sources/PacKit/Topology+Helpers.swift` — add `import CoreGraphics` after `import Foundation`, and after `snap(_:grid:)` add:

```swift
/// World rectangle holding every device box (`nodeSize`, centred on its position) plus `margin`: what Esporta immagine draws.
/// nil without devices.
public func exportBounds(_ centers: [Pos], nodeSize: CGSize, margin: Double) -> CGRect? {
    let boxes = centers.map { CGRect(x: $0.x - nodeSize.width / 2, y: $0.y - nodeSize.height / 2, width: nodeSize.width, height: nodeSize.height) }
    guard let first = boxes.first else { return nil }
    return boxes.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -margin, dy: -margin)
}
```

Run: `scripts/test.sh 2>&1 | tail -5` → all pass (1 more).

- [ ] **Step 4: Selftest scenario (RED)**

In `SelfTest.scenario(output:)` after `failures += await pingScenario(output: output)` add `failures += await exportScenario(output: output)` and:

```swift
    /// M6: File ▸ Esporta immagine… draws every device at 2× with a 40 pt margin, also left of the origin.
    private static func exportScenario(output: String) async -> [String] {
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 140, y: 70))
        await editor.addDevice(.pc, at: Pos(x: 0, y: 210))
        await editor.addDevice(.pc, at: Pos(x: 280, y: 210))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        await editor.connect(ids[0], ids[2])
        guard let data = ExportImage.png(editor), let rep = NSBitmapImageRep(data: data) else { return ["export produced no PNG"] }
        // Boxes span x −52…332 and y 47…233; with the margin 464 × 266 pt, at 2×.
        var failures = rep.pixelsWide == 928 && rep.pixelsHigh == 532 ? [] : ["export size \(rep.pixelsWide)×\(rep.pixelsHigh)"]
        if (try? data.write(to: URL(fileURLWithPath: sibling(output, "m6-export")))) == nil { failures.append("could not write the export") }
        return failures
    }
```

Run: `scripts/selftest.sh build/selftest.png` → build error `cannot find 'ExportImage' in scope` (the RED).

- [ ] **Step 5: Implement the export**

`Sources/PacTrack/CanvasView.swift`:
- After the `@State` properties add:

```swift
    /// Set only by the PNG export: the pan that frames the network; no event monitor, no minimap.
    private let exportOffset: CGSize?

    init(editor: Editor, exportOffset: CGSize? = nil) {
        _editor = Bindable(editor)
        self.exportOffset = exportOffset
        _offset = State(initialValue: exportOffset ?? .zero)
    }
```

- In `.onAppear { … }` (the monitor), first line `guard exportOffset == nil else { return }`.
- The minimap overlay condition becomes `if exportOffset == nil && !editor.snapshot.nodes.isEmpty { minimap(geo.size) }`.

Create `Sources/PacTrack/ExportImage.swift`:

```swift
import AppKit
import PacKit
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Esporta immagine… (spec §8): every device and cable as a PNG at 2×, framed with a margin, as on screen.
@MainActor
enum ExportImage {
    static func png(_ editor: Editor) -> Data? {
        let centers = editor.snapshot.nodes.compactMap { editor.positions[$0.id] }
        guard let r = exportBounds(centers, nodeSize: CanvasView.nodeSize, margin: 40) else { return nil }
        let content = CanvasView(editor: editor, exportOffset: CGSize(width: -r.minX, height: -r.minY))
            .frame(width: r.width, height: r.height)
            .foregroundStyle(Theme.fg)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func save(_ editor: Editor) {
        guard let data = png(editor) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "rete.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
```

`Sources/PacTrack/PacTrackApp.swift` — `EditCommands`' doc comment becomes `/// Menu commands of the focused window: undo/redo, the device pasteboard, grid, PNG export. Inside a text field the editing shortcuts edit the text.` and its `body` gains:

```swift
        CommandGroup(after: .saveItem) {
            Button("Esporta immagine…") { if let editor { ExportImage.save(editor) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor?.snapshot.nodes.isEmpty ?? true)
        }
```

- [ ] **Step 6: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m6-export.png`: 928 × 532, dark background, SW1 above PC1 and PC2 (PC1 not cut off on the left), both cables with labels, icons and names light on dark. `scripts/test.sh` stays green.

- [ ] **Step 7: Commit**

```bash
git add Sources/PacKit/Topology+Helpers.swift Sources/PacTrack/CanvasView.swift Sources/PacTrack/ExportImage.swift Sources/PacTrack/PacTrackApp.swift Sources/PacTrack/SelfTest.swift Tests/PacKitTests/HelpersTests.swift
git commit -m "feat(app): export the canvas as a PNG with ImageRenderer from File > Esporta immagine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: App icon in the signed bundle

**Files:**
- Create: `scripts/make-icon.swift`
- Modify: `scripts/bundle.sh`, `Resources/Info.plist`

- [ ] **Step 1: Check the tools**

Run: `which swiftc iconutil codesign sips`
Expected: four paths under `/usr/bin`.

- [ ] **Step 2: Write the icon generator**

Create `scripts/make-icon.swift`:

```swift
// Draws the app icon into an .iconset folder (run by scripts/bundle.sh): a dark tile, three devices cabled in a triangle
// in the protocol colours, an ICMP packet on the bottom cable.
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// One square PNG, `px` pixels wide, drawn on a 1024-point grid.
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824-point tile with 185-point corners, centred.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    color(0x2B2D30).setFill()
    tile.fill()
    color(0x393B40).setStroke()
    tile.lineWidth = 8 * s
    tile.stroke()
    let nodes = [NSPoint(x: 512 * s, y: 700 * s), NSPoint(x: 300 * s, y: 330 * s), NSPoint(x: 724 * s, y: 330 * s)]
    let cable = NSBezierPath()
    cable.move(to: nodes[0])
    cable.line(to: nodes[1])
    cable.line(to: nodes[2])
    cable.close()
    color(0x6F737A).setStroke()
    cable.lineWidth = 22 * s
    cable.stroke()
    for (p, hex) in zip(nodes, [UInt32(0x3574F0), 0x5FB865, 0xB083F0]) {
        color(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: p.x - 95 * s, y: p.y - 70 * s, width: 190 * s, height: 140 * s), xRadius: 28 * s, yRadius: 28 * s).fill()
    }
    color(0xE5507A).setFill()
    NSBezierPath(ovalIn: NSRect(x: 468 * s, y: 286 * s, width: 88 * s, height: 88 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
```

- [ ] **Step 3: Bundle the icon**

`scripts/bundle.sh` becomes:

```sh
#!/bin/sh
# Builds build/PacTrack.app (release, icon, ad-hoc signed) without Xcode.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product PacTrack
APP=build/PacTrack.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PacTrack "$APP/Contents/MacOS/PacTrack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O scripts/make-icon.swift -o .build/make-icon
.build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
```

`Resources/Info.plist` — after the `CFBundleDisplayName` line add:

```xml
    <key>CFBundleIconFile</key><string>AppIcon</string>
```

- [ ] **Step 4: Verify**

Run each and compare:
- `plutil -lint Resources/Info.plist` → `Resources/Info.plist: OK`
- `scripts/bundle.sh` → ends with `build/PacTrack.app`
- `ls build/AppIcon.iconset | wc -l` → `10`
- `sips -g pixelWidth build/AppIcon.iconset/icon_512x512@2x.png` → `pixelWidth: 1024`
- `/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" build/PacTrack.app/Contents/Info.plist` → `AppIcon`
- `codesign -dv build/PacTrack.app 2>&1 | grep Signature` → `Signature=adhoc`
- `codesign --verify --strict --verbose=2 build/PacTrack.app` → `valid on disk` and `satisfies its Designated Requirement`

Read `build/AppIcon.iconset/icon_512x512@2x.png`: dark rounded tile, blue/green/purple devices on a grey triangle, a pink dot on the bottom cable. Read `build/AppIcon.iconset/icon_16x16.png`: still a recognisable tile.

- [ ] **Step 5: Commit**

```bash
git add scripts/make-icon.swift scripts/bundle.sh Resources/Info.plist
git commit -m "build: draw the app icon at bundle time and verify the ad-hoc signature

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: README for v3, remove v1

**Files:**
- Modify: `README.md`
- Create: `docs/screenshot.png`
- Delete: `legacy/` (`app.js`, `index.html`, `package.json`, `styles.css`), `preview.png`

- [ ] **Step 1: Screenshot**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; then `cp build/selftest-m4.png docs/screenshot.png` (traffic, metrics chart and event list in one image). Read `docs/screenshot.png` to confirm it shows a populated canvas.

- [ ] **Step 2: Write the README**

Replace `README.md` with:

````markdown
# Pac-Track

Simulatore di reti per macOS, fedele ai protocolli e realistico nei tempi: disegni una rete, la configuri e guardi ARP, switching, routing, DHCP, DNS, TCP, NAT e firewall pacchetto per pacchetto, con i campi reali di ogni header.

![Pac-Track](docs/screenshot.png)

## Cosa fa

- **Dispositivi**: PC, laptop, server, router, switch (8, 24 o 48 porte), hub e Cloud/ISP, un router con un'uscita "Internet" simulata che risponde a ping e fa da DNS pubblico.
- **Protocolli**: Ethernet con MAC learning e ARP; IPv4 con routing statico; ICMP (ping, traceroute); DHCP (DORA, rinnovo, scadenza) e DNS (record A, cache con TTL, NXDOMAIN, nslookup); UDP e TCP (handshake, finestra, ritrasmissioni RFC 6298, fast retransmit, Reno); NAT/PAT e firewall stateful sui router.
- **Tempo**: modalità Realtime (da 0.1× a 100×) e Simulation (orologio fermo, un evento alla volta). Stesso seed e stessa rete danno la stessa simulazione.
- **Osservare**: lista eventi filtrabile e ispettore PDU header per header; pacchetti colorati per protocollo sui cavi; tabelle live (ARP, MAC, routing, NAT, lease DHCP, cache DNS, connessioni TCP); generatore di traffico TCP/UDP con metriche (utilizzo e code dei cavi, throughput, RTT, jitter, perdita).
- **Documento**: file `.ptk` (JSON) con apertura, salvataggio automatico, versioni e finestre multiple di macOS; annulla e ripeti; esportazione PNG del canvas.

## Requisiti

macOS 15 o successivo. Per compilare: Swift 6 con i soli Command Line Tools (`xcode-select --install`); Xcode non serve.

## Installazione

```sh
scripts/bundle.sh          # crea build/PacTrack.app (release, icona, firma ad-hoc)
open build/PacTrack.app
```

Per tenerla, trascina `build/PacTrack.app` in Applicazioni.

## Primi passi

1. Trascina dalla palette uno switch e due PC; collegali trascinando dal pallino in basso di un dispositivo all'altro (oppure scegli un cavo nella palette, o lo strumento **Collega**).
2. Seleziona il primo PC: nell'ispettore, scheda *Interfacce*, scrivi `10.0.0.1/24` e premi Invio; al secondo `10.0.0.2/24`.
3. Tasto destro sul primo PC ▸ *Ping verso* ▸ il secondo: l'output compare in basso, i pacchetti in *Eventi*.
4. Passa a *Simulation* nella barra e premi `.` per avanzare un evento alla volta; un clic su un evento mostra la sua PDU.
5. Per uscire su Internet: aggiungi una *Cloud/ISP* (Gi0/0 già su `203.0.113.1/24`), dai al tuo router `203.0.113.2/24` verso di lei, la route `0.0.0.0/0` via `203.0.113.1` e il NAT (*Servizi*); i PC usano `8.8.8.8` come DNS e raggiungono `www.example.com`.

Scorciatoie: V sposta, C collega, Canc elimina, Spazio avvia o ferma, `.` passo, Cmd+Z e Cmd+Shift+Z, Cmd+C, Cmd+V, Cmd+D, Cmd+A, Cmd+S, Cmd+O, Cmd+Shift+E esporta l'immagine. Shift-clic e Shift-trascina selezionano più dispositivi.

## Sviluppo

```sh
scripts/test.sh                          # test (Swift Testing) con i soli Command Line Tools
scripts/selftest.sh build/selftest.png   # avvia l'app, esegue uno scenario scriptato e salva le schermate
```

- `Sources/PacEngine`: motore a eventi discreti in Swift puro (solo Foundation).
- `Sources/PacKit`: comandi e snapshot, formato file, actor della simulazione, editor con annulla e ripeti.
- `Sources/PacTrack`: app SwiftUI.
- `docs/superpowers/specs`: specifica; `docs/superpowers/plans`: piani delle milestone; `docs/manual-checks`: verifiche manuali.

Convenzioni: testi dell'interfaccia in italiano; codice, commenti e commit in inglese; ogni funzione nuova parte da un test che fallisce.

## Fuori perimetro

Wi-Fi, VLAN 802.1Q, STP, routing dinamico (RIP, OSPF), IPv6, CLI per dispositivo, applicazioni oltre DNS e DHCP.

## Licenza

MIT, vedi [LICENSE](LICENSE).
````

- [ ] **Step 3: Remove v1**

Run: `git rm -r legacy preview.png`
Expected: `rm 'legacy/app.js'`, `rm 'legacy/index.html'`, `rm 'legacy/package.json'`, `rm 'legacy/styles.css'`, `rm 'preview.png'`. (`CONTRIBUTING.md`, `.gitignore`, `NEXT_STEPS.md` and `electron-app/` stay untouched — the user decides.)

- [ ] **Step 4: Verify**

- `git ls-files legacy preview.png` → no output
- `git grep -n -i -E "legacy/|preview\.png" -- . ':!docs/superpowers'` → no output
- `grep -c -i -E "index\.html|npm|javascript|html5" README.md` → `0`
- `test -f docs/screenshot.png && echo ok` → `ok`
- `scripts/test.sh 2>&1 | tail -1` → all pass; `swift build` → builds (nothing referenced v1).

- [ ] **Step 5: Commit**

```bash
git add README.md docs/screenshot.png
git commit -m "docs: rewrite the README for v3 in Italian and remove v1 (legacy/ and its screenshot)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(`git rm` already staged the deletions; `git status --short` before committing must list only `README.md`, `docs/screenshot.png`, the four `legacy/` files and `preview.png`, plus the untracked `NEXT_STEPS.md` and `electron-app/`.)

---

### Task 13: Manual checklist and end-to-end verification

**Files:**
- Create: `docs/manual-checks/m6.md`

- [ ] **Step 1: Write the checklist**

```markdown
# M6 — manual checks

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**App and packaging**
- [ ] Finder and the Dock show the Pac-Track icon (dark tile, three devices on a triangle, a pink packet). If Finder still shows a generic icon: `touch build/PacTrack.app`.
- [ ] `codesign -dv build/PacTrack.app` reports `Signature=adhoc`; a double-click opens the app.
- [ ] File ▸ *Esporta immagine…* (Cmd+Shift+E) with three cabled devices, one of them left of the window: the save panel proposes `rete.png`; the PNG shows every device and cable on the dark background, none cut off, sharp. With an empty canvas the item is greyed out.

**Selection**
- [ ] Shift-click two devices: both outlined, the inspector reads "2 dispositivi selezionati…". Shift-click one again: only the other stays selected and its inspector opens.
- [ ] Shift-drag on empty canvas draws a dashed rectangle and selects the devices inside; a plain drag still pans.
- [ ] Drag one of the selected devices: all move together; one Cmd+Z puts them all back.
- [ ] Right-click a selected device: only *Duplica, Copia, Spegni/Accendi, Elimina*; each acts on all of them and is one Cmd+Z step. Cmd+C, Cmd+V pastes the group with its shape and new names.
- [ ] Right-click empty canvas ▸ *Seleziona tutto*, and Cmd+A outside text fields, select every device; inside a field Cmd+A selects the text.
- [ ] Modifica ▸ *Elimina* deletes the selection; Backspace on the canvas too; Backspace in a field deletes a character.
- [ ] Cmd+D while typing in a field duplicates nothing.
- [ ] Right-click a PC ▸ *Mostra tabelle*: the inspector opens on Tabelle (a hub has no such item).

**Tools, cables, grid, minimap**
- [ ] Toolbar *Sposta | Collega*; with the canvas focused V and C switch tools; typing v or c in a field types the letter.
- [ ] Palette ▸ CAVI ▸ *Fibra 10 Gb/s*: the tool becomes Collega; drag from a switch to a server: the cable reads `… · 10 Gb/s · 5 µs`. *Personalizzato*: the new cable opens in the inspector. Cmd+Z removes a cable with its settings in one step. Every cable label ends with its delay (`0.5 µs` for Ethernet).
- [ ] Right-click empty canvas (or Vista) ▸ *Nascondi griglia*: dots disappear and devices move freely; *Mostra griglia* brings both back.
- [ ] The minimap bottom-right shows the devices and the visible area; a click centres the view there.

**Devices**
- [ ] Switch ▸ Porte ▸ 24: ports Gi0/1…Gi0/24. Cable nine PCs to it (Cmd+D duplicates; the ninth lands on Gi0/9), choose 8: `Gi0/9 is connected` under the picker, nothing changes. Remove the ninth PC, choose 8: done; Cmd+Z restores 24. Save, reopen: the size is kept.
- [ ] Palette ▸ Rete ▸ *Cloud/ISP*: ISP1 appears with Gi0/0 `203.0.113.1/24`; Servizi shows the Internet note, the DHCP toggle and `www.example.com  198.51.100.10`. Cmd+Z removes it in one step.
- [ ] PC1 (192.168.1.10/24, gateway 192.168.1.1, DNS 8.8.8.8) — R1 (Gi0/0 192.168.1.1/24 inside, Gi0/1 203.0.113.2/24 outside, route 0.0.0.0/0 via 203.0.113.1) — ISP1: ping `8.8.8.8` and `www.example.com` answer with `ttl=254`; nslookup `www.example.com` gives `Address: 198.51.100.10`; traceroute `198.51.100.10` ends at hop 2 `198.51.100.10`.
- [ ] From PC1, ping `10.9.9.9`: `From 203.0.113.1 … Destination Net Unreachable`; ping `203.0.113.99`: `… Destination Host Unreachable` after the ARP timeout.
- [ ] Two PCs on one switch: give the second the first one's address: `Duplicate address: … is already used by PC1 eth0 on this segment` under the field, address unchanged. Cable a third PC that already has that address: the cable goes in; save, close, reopen: it opens.

**Apps and clock**
- [ ] App tab: Pacchetti 2, Intervallo 0.2, Byte 1472: `PING … 1472(1500) bytes of data.` and two replies of 1480 bytes. TTL `0`: `Invalid ping option: TTL must be between 1 and 255`; Pacchetti `due`: `Invalid number: "due"`; nothing starts.
- [ ] Two switches cabled twice and a PC pinging any address, speed 100×: the toolbar shows `effettiva …×` in orange next to the clock; pause: it disappears.

**Repository**
- [ ] `README.md` (Italian) describes v3 with the screenshot; `legacy/` and `preview.png` are gone.
```

- [ ] **Step 2: Full verification**

Run, in order:
- `scripts/test.sh 2>&1 | tail -3` → all pass (226 at the start of M6 + 17 = 243, more if the M5 review fixes added tests).
- `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`; Read `build/selftest.png` and every `build/selftest-m6-*.png` once more.
- `scripts/bundle.sh` → `build/PacTrack.app`.
- Launch `build/PacTrack.app/Contents/MacOS/PacTrack > build/run.log 2>&1 &` for ~5 s, confirm it runs (`pgrep -x PacTrack` prints a pid) and `build/run.log` is empty, then `pkill -x PacTrack`.
- `git status --short` → only `?? NEXT_STEPS.md`, `?? electron-app/` and the new checklist.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-checks/m6.md
git commit -m "docs: add the M6 manual checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Out of scope (recorded)

- Saving zoom and pan (`view` in `.ptk`, spec §8): left to the user's decision (it would mark the document edited on every pan).
- Notarization, Developer ID signing, DMG or zip: ad-hoc signing as spec §4; a copy sent to another Mac needs right-click ▸ Apri.
- Bare-key menu shortcuts (V, C, Space, `.`), cables kept between copied devices, a context menu for a multiple selection that mixes cables, saving grid/tool/cable kind.
- Cloud: NAT or firewall on the cloud, several Internet behaviours (delay, loss towards the Internet), real far-side servers inside the cloud, a customer-facing DHCP client on routers.
- Router port counts other than 4; hub sizes other than 8.
- `CONTRIBUTING.md` (v1's JavaScript guide), `.gitignore`'s Node sections, untracked `NEXT_STEPS.md` and `electron-app/`: for the user to decide.
