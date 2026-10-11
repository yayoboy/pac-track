# M10 — More host devices: printer, Smart TV, DNS and DHCP server presets (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four new palette entries that work as soon as they are dropped (spec M10 §1–§3): *Stampante* (a host with the traffic sink on), *Smart TV* (a host in DHCP), *Server DNS* and *Server DHCP* (a plain server with the service on); the palette in sections that scroll; copies keep the sink.

**Architecture:**
- Two new `DeviceKind` cases, `printer` and `tv`, appended to the enum; the engine builds a `Host` for both and admits the sink on `printer` as on `server`. Nothing else in the engine changes.
- Per-kind defaults live where the Cloud's already are: `Editor.addDeviceNow` appends commands to the same undo step.
- `ServerPreset` (PacKit) names the two server presets; `Editor.addDevice(_:at:preset:)` applies one. Saved files hold plain servers.
- `PaletteItem` (PacTrack, `PaletteView.swift`) is one palette entry (a kind plus an optional preset) with the drag payload; the canvas drop and the *Aggiungi dispositivo* menu read the palette's entries.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM, Command Line Tools only — no Xcode.

**Spec:** `docs/superpowers/specs/2026-10-11-m10-host-devices-design.md`. It extends `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2) and M3–M9.

Conventions: `docs/superpowers/plans/2026-10-11-m9b-ipv6-services.md`; ledger `.superpowers/sdd/2026-10-11-m10-host-devices/progress.md` in the style of `.superpowers/sdd/2026-10-11-m9b-ipv6-services/progress.md`.

## Global Constraints

- **Running commands.** Every `swift`/`scripts/*.sh` command runs **outside the sandbox**. Unit tests only via `scripts/test.sh` (bare `swift test` runs zero tests with CLT); one suite with `scripts/test.sh --filter <Suite>`. End-to-end: `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`. Baseline: `✔ Test run with 400 tests in 54 suites passed`.
- **Git.** Work in place on branch `m10/devices`; never switch branches, never push, no PRs. Stage only the files a task lists, one conventional commit per task, trailer:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VKg7UVJhJdqPhWvu8DgXn7
  ```
- **Engine rules.** The Sim owns its nodes; node→sim is `unowned`. Never store `SimTimer`s. The UI holds only `Snapshot` values and string ids. Deterministic iteration order. Tests keep the `Sim` alive while nodes run.
- **Edits.** Every network change goes through `Editor.edit`/`editNow`; a device and its defaults are one undo step.
- **`.ptk`.** `Topology.version` stays `1`. New kind raw values `printer`, `tv`; no new keys. Presets save as `server`.
- **Copy and style.** UI copy Italian (`Stampante`, `Smart TV`, `Server DNS`, `Server DHCP`, sections `Rete`, `Host`, `Server`, `Cavi`); engine errors English; code, comments, tests, commits English. Colours only via `Theme`.
- **Ponytail/YAGNI.** Every API below has a consumer in this plan; nothing for M11 (wireless). Never delete existing lines or comments a task does not require changing.
- **Out of scope (spec §4):** IP phone, web server, hosts with more than one NIC, tablet and smartphone (M11), port 9100.

## Review Focus

1. **Old files and old kinds.** Appending `printer`/`tv` must not change how M1–M9 files open or how existing kinds behave (tabs, names, services). Pinned by the full suite plus `printersAndTvsAreHostsWithItalianNamesAndTabs` (Task 1).
2. **Defaults survive saving, undo and copies.** A printer saved with its sink off reopens off (the default lives in the editor, not the engine); a copied printer keeps the sink; a copied DHCP preset is a plain server (pool not copied). Pinned by `aPrinterArrivesWithTheSinkAndATvInDhcpEachInOneStep` and `copiesKeepTheSink` (Task 2).
3. **Services gating.** The sink is refused on a Smart TV, DHCP/DNS servers on both new kinds; the Servizi tab of a printer shows only the sink (the DHCP toggle would hit an engine error). Pinned by `aPrinterReceivesTrafficAndATvIsAPlainHost` (Task 1) and the M10 selftest image (Task 4).
4. **The spec lab as dropped.** Nothing typed on SRV1 and TV1: leases at 60 s and TCP to the printer finishes. Pinned by `theSpecLabWorksAsDropped` (Task 3) and the selftest (Task 4).
5. **Palette at the minimum window height.** 14 entries, 4 headers and the hint in 170 pt × ~588 pt: the list scrolls, nothing wraps or is cut. Pinned by the `m10-palette-short` selftest image (Task 4), read by eye.

## Spec coverage

| M10 spec | Task |
|---|---|
| §2 new kinds (engine, labels, names, icons, tabs, sink gating, Servizi of a printer) | 1 |
| §2 defaults (printer sink, TV DHCP), §6 copies keep the sink, round-trip | 2 |
| §3 server presets, §1 success lab | 3 |
| §5 palette sections, scroll, search, canvas menu; §7 selftest images | 4 |
| §7 manual checks, README | 5 |

## Rulings (where the spec is silent)

Each line gives the ruling, why, and the cost if wrong.

- **New cases appended** (`… cloud, printer, tv`). Why: raw values decide the file format, order only `allCases`, which no longer drives any UI after Task 4. Cost if wrong: none.
- **Name prefixes `PRN` and `TV`.** Why: short like `SRV`, `SW`. Cost if wrong: a name.
- **Icons `printer` and `tv`** (SF Symbols 1, available on macOS 15). Cost if wrong: an icon.
- **The Servizi tab of a printer is the sink alone** (`else if node.kind == .printer { sink }`). Why: DHCP and DNS servers are refused on printers by the engine. Cost if wrong: none.
- **Presets keep the server icon** in the palette. Why: on the canvas they are servers; a different palette icon would not match what lands. Cost if wrong: three equal icons in the Server section.
- **`ServerPreset` raw values `server-dns`, `server-dhcp`** double as drag payloads; they cannot collide with a kind's raw value. Cost if wrong: none.
- **The canvas menu lists the palette's entries** (`PaletteView.groups(matching: "")`) instead of `DeviceKind.allCases`, so presets are there too and the order matches. Cost if wrong: none.
- **`SelfTest.render` gains `height:` (default 860)** for the one short-window image. Cost if wrong: one parameter.

---

### Task 1: Printer and Smart TV kinds

**Files:**
- Modify: `Sources/PacEngine/Runtime/Protocol.swift` (`DeviceKind`)
- Modify: `Sources/PacEngine/Runtime/Runtime.swift` (`create`, `.setSink`)
- Modify: `Sources/PacKit/Topology+Helpers.swift` (`label`, `namePrefix`, `isHost`, `inspectorTabs`)
- Modify: `Sources/PacTrack/Theme.swift` (`symbol`)
- Modify: `Sources/PacTrack/ServicesTab.swift` (body, doc comment)
- Test: `Tests/PacEngineTests/RuntimeTrafficTests.swift`, `Tests/PacKitTests/HelpersTests.swift`

**Interfaces:**
- Produces: `DeviceKind.printer`, `DeviceKind.tv`; labels `Stampante`, `Smart TV`; prefixes `PRN`, `TV`; symbols `printer`, `tv`.

- [ ] **Step 1: Write the failing tests**

In `RuntimeTrafficTests` (after `poweringTheSenderOffEndsItsFlow`'s neighbours, inside the suite):

```swift
    /// Spec M10 §2: both are hosts; the printer runs the sink, the Smart TV runs no service.
    @Test func aPrinterReceivesTrafficAndATvIsAPlainHost() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "p", kind: .printer, name: "PRN1"))
        try rt.handle(.addNode(id: "t", kind: .tv, name: "TV1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "t", iface: "eth0"), b: IfaceRef(node: "p", iface: "eth0")))
        try rt.handle(.setIp(node: "p", iface: "eth0", cidr: "10.0.0.50/24"))
        try rt.handle(.setIp(node: "t", iface: "eth0", cidr: "10.0.0.1/24"))
        try rt.handle(.setSink(node: "p", on: true))
        try rt.handle(.trafficTcp(node: "t", target: "10.0.0.50", bytes: 100_000))
        try rt.handle(.ping(node: "p", target: "10.0.0.1"))
        runFor(rt, wallMs: 5_000)
        let s = rt.snapshot()
        #expect(s.nodes.map(\.kind) == [.printer, .tv] && s.nodes[0].sink)
        #expect(s.apps[0].lines.last == "iperf Done.")
        #expect(s.apps[1].lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        expectError("TV1 cannot run a traffic sink") { try rt.handle(.setSink(node: "t", on: true)) }
        expectError("PRN1 cannot run a DHCP server") {
            try rt.handle(.setDhcpServer(node: "p", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199")))
        }
        expectError("TV1 cannot run a DNS server") { try rt.handle(.setDnsServer(node: "t", records: [])) }
        try rt.handle(.setIfaceMode(node: "t", iface: "eth0", mode: .dhcp))
        #expect(rt.snapshot().nodes[1].ifaces[0].mode == .dhcp)
    }
```

In `HelpersTests`:

```swift
    @Test func printersAndTvsAreHostsWithItalianNamesAndTabs() {
        #expect([DeviceKind.printer, .tv].map(\.label) == ["Stampante", "Smart TV"])
        #expect(defaultName(.printer, taken: ["PRN1"]) == "PRN2" && defaultName(.tv, taken: []) == "TV1")
        #expect(DeviceKind.printer.isHost && DeviceKind.tv.isHost && DeviceKind.printer.hasIp)
        #expect(inspectorTabs(for: .printer) == [.interfaces, .routing, .services, .tables, .app])
        #expect(inspectorTabs(for: .tv) == [.interfaces, .routing, .tables, .app])
        #expect(inspectorTabs(for: .pc) == [.interfaces, .routing, .tables, .app]) // unchanged
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test.sh --filter "RuntimeTrafficTests|HelpersTests"`
Expected: build error `type 'DeviceKind' has no member 'printer'`.

- [ ] **Step 3: Implement**

`Protocol.swift`:
```swift
/// `cloud`: an ISP edge router whose "Internet" answers by itself (spec §5.5). `printer`, `tv`: hosts (spec M10 §2).
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case pc, laptop, server, router, `switch`, hub, cloud, printer, tv
}
```
`Runtime.swift` — `create`: `case .pc, .laptop, .server, .printer, .tv: Host(sim: sim, id: id)`; `.setSink`: `guard !on || nodes[node]?.kind == .server || nodes[node]?.kind == .printer else { … }`.

`Topology+Helpers.swift`: `label` `case .printer: "Stampante"`, `case .tv: "Smart TV"`; `namePrefix` `case .printer: "PRN"`, `case .tv: "TV"`; `isHost` doc "PCs, laptops, servers, printers and Smart TVs" and `[.pc, .laptop, .server, .printer, .tv].contains(self)`; `inspectorTabs`: `case .router, .server, .cloud, .printer:` and `case .pc, .laptop, .tv:`.

`Theme.swift`: `case .printer: "printer"`, `case .tv: "tv"`.

`ServicesTab.swift` body:
```swift
            if node.kind == .switch {
                spanningTree
            } else if node.kind == .printer {
                sink
            } else {
```
and the doc comment: "sink (servers, printers)".

- [ ] **Step 4: Run to verify they pass**

Run: `scripts/test.sh` → 402 tests pass; `swift build --product PacTrack` builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Sources/PacKit/Topology+Helpers.swift Sources/PacTrack/Theme.swift Sources/PacTrack/ServicesTab.swift Tests/PacEngineTests/RuntimeTrafficTests.swift Tests/PacKitTests/HelpersTests.swift
git commit -m "feat(engine): printer and Smart TV host kinds; the printer runs the traffic sink"
```

### Task 2: Kind defaults and copies that keep the sink

**Files:**
- Modify: `Sources/PacKit/Editor.swift` (`addDeviceNow`, `insertCopies` and its doc comment)
- Test: `Tests/PacKitTests/DeviceEditorTests.swift`

**Interfaces:**
- Consumes: Task 1's kinds.

- [ ] **Step 1: Write the failing tests** (in `DeviceEditorTests`)

```swift
    @Test func aPrinterArrivesWithTheSinkAndATvInDhcpEachInOneStep() async throws {
        await editor.addDevice(.printer, at: Pos(x: 0, y: 0))
        await editor.addDevice(.tv, at: Pos(x: 100, y: 0))
        let (prn, tv) = (editor.snapshot.nodes[0], editor.snapshot.nodes[1])
        #expect(prn.name == "PRN1" && prn.sink && prn.ifaces.map(\.name) == ["eth0"] && prn.ifaces[0].cidr == nil && prn.ifaces[0].mode == .static)
        #expect(tv.name == "TV1" && !tv.sink && tv.ifaces[0].mode == .dhcp)
        let saved = editor.current
        #expect(try ProjectFile.decode(try ProjectFile.encode(saved)) == saved)
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.name) == ["PRN1"]) // the TV and its mode in one step
        await editor.undo()
        #expect(editor.snapshot.nodes.isEmpty)
        let opened = await editor.load(saved)
        #expect(opened && editor.snapshot.nodes.map(\.kind) == [.printer, .tv])
        #expect(editor.snapshot.nodes[0].sink && editor.snapshot.nodes[1].ifaces[0].mode == .dhcp)
        // The default is the editor's: a printer saved with the sink off opens with it off.
        await editor.edit(.setSink(node: editor.snapshot.nodes[0].id, on: false))
        let off = editor.current
        _ = await editor.load(off)
        #expect(!editor.snapshot.nodes[0].sink)
    }

    @Test func copiesKeepTheSink() async {
        await editor.addDevice(.printer, at: Pos(x: 0, y: 0))
        await editor.addDevice(.server, at: Pos(x: 100, y: 0))
        await editor.addDevice(.printer, at: Pos(x: 200, y: 0))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.edit(.setSink(node: ids[1], on: true))
        await editor.edit(.setSink(node: ids[2], on: false))
        await editor.duplicate(ids)
        #expect(editor.snapshot.nodes.map { "\($0.name) \($0.sink)" }
            == ["PRN1 true", "SRV1 true", "PRN2 false", "PRN3 true", "SRV2 true", "PRN4 false"])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test.sh --filter DeviceEditorTests`
Expected: 2 failures (`prn.sink` false, `tv` mode static; copies without the sink).

- [ ] **Step 3: Implement** — `addDeviceNow`, after the Cloud block:

```swift
        // A printer receives print jobs (the generator's traffic); a Smart TV takes its address like out of the box (spec M10 §2).
        if kind == .printer { cmds.append(.setSink(node: id, on: true)) }
        if kind == .tv { cmds.append(.setIfaceMode(node: id, iface: "eth0", mode: .dhcp)) }
```
`insertCopies`, after the name-server line:
```swift
            // The sink is a switch, not an address (spec M10 §6): a copied printer still receives.
            if src.sink { cmds.append(.setSink(node: id, on: true)) }
```
and its doc comment: "…interface modes, sink, IPv6 and SLAAC settings…".

- [ ] **Step 4: Run** `scripts/test.sh` → 404 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacKit/Editor.swift Tests/PacKitTests/DeviceEditorTests.swift
git commit -m "feat(editor): a printer arrives with the sink on, a Smart TV in DHCP; copies keep the sink"
```

### Task 3: Server presets

**Files:**
- Modify: `Sources/PacKit/Topology+Helpers.swift` (new `ServerPreset` after the `DeviceKind` extension)
- Modify: `Sources/PacKit/Editor.swift` (`addDevice`, `addDeviceNow`)
- Test: `Tests/PacKitTests/DeviceEditorTests.swift`

**Interfaces:**
- Produces: `public enum ServerPreset: String, Sendable { case dns = "server-dns", dhcp = "server-dhcp"; public var label: String }`; `Editor.addDevice(_ kind: DeviceKind, at pos: Pos, preset: ServerPreset? = nil) async` (preset used with `.server`).

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func serverPresetsArriveWithTheirServiceInOneStep() async {
        await editor.addDevice(.server, at: Pos(x: 0, y: 0), preset: .dhcp)
        await editor.addDevice(.server, at: Pos(x: 100, y: 0), preset: .dns)
        let (dhcp, dns) = (editor.snapshot.nodes[0], editor.snapshot.nodes[1])
        #expect(dhcp.kind == .server && dhcp.name == "SRV1" && dhcp.ifaces[0].cidr == "192.168.1.2/24")
        #expect(dhcp.dhcpServer == DhcpConfig(start: "192.168.1.100", end: "192.168.1.199") && dhcp.dnsRecords == nil)
        #expect(dns.kind == .server && dns.name == "SRV2" && dns.ifaces[0].cidr == "192.168.1.3/24" && dns.dnsRecords == [] && dns.dhcpServer == nil)
        #expect([ServerPreset.dns, .dhcp].map(\.label) == ["Server DNS", "Server DHCP"])
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.name) == ["SRV1"])
        await editor.undo()
        #expect(editor.snapshot.nodes.isEmpty)
    }

    /// Spec M10 §1: SW1, a Server DHCP, a Smart TV, a printer at 192.168.1.50 and a PC in DHCP, nothing else typed.
    @Test func theSpecLabWorksAsDropped() async {
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        await editor.addDevice(.server, at: Pos(x: 0, y: 100), preset: .dhcp)
        await editor.addDevice(.tv, at: Pos(x: 100, y: 100))
        await editor.addDevice(.printer, at: Pos(x: 200, y: 100))
        await editor.addDevice(.pc, at: Pos(x: 300, y: 100))
        let node = { (name: String) in self.editor.snapshot.nodes.first { $0.name == name }! }
        for name in ["SRV1", "TV1", "PRN1", "PC1"] { await editor.connect(node("SW1").id, node(name).id) }
        await editor.edit(.setIp(node: node("PRN1").id, iface: "eth0", cidr: "192.168.1.50/24"))
        await editor.edit(.setIfaceMode(node: node("PC1").id, iface: "eth0", mode: .dhcp))
        // Ports forward at 30 s (STP); the DISCOVER retries at 4, 12, 28 and 60 s.
        for _ in 0..<610 { await editor.tick(wallMs: 100) }
        #expect(Set([node("TV1").ifaces[0].cidr, node("PC1").ifaces[0].cidr]) == ["192.168.1.100/24", "192.168.1.101/24"])
        await editor.startTraffic(node("PC1").id, target: "192.168.1.50", kind: .tcp, amount: "100000", seconds: "")
        for _ in 0..<20 { await editor.tick(wallMs: 100) }
        #expect(editor.snapshot.apps.last?.lines.last == "iperf Done.")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test.sh --filter DeviceEditorTests`
Expected: build error `extra argument 'preset' in call`.

- [ ] **Step 3: Implement**

`Topology+Helpers.swift`, after the `DeviceKind` extension:
```swift
/// Palette entries that drop a plain server with a service already on (spec M10 §3); the raw value is the drag payload.
public enum ServerPreset: String, Sendable {
    case dns = "server-dns", dhcp = "server-dhcp"

    public var label: String { self == .dns ? "Server DNS" : "Server DHCP" }
}
```
`Editor.swift`:
```swift
    public func addDevice(_ kind: DeviceKind, at pos: Pos, preset: ServerPreset? = nil) async {
        await serialized { await self.addDeviceNow(kind, at: pos, preset: preset) }
    }

    private func addDeviceNow(_ kind: DeviceKind, at pos: Pos, preset: ServerPreset?) async {
```
and after the Task 2 defaults:
```swift
        // Server presets (spec M10 §3): 192.168.1.0/24 with .1 left to the router; the pool is the one the Servizi switch suggests.
        switch preset {
        case .dhcp?: cmds += [.setIp(node: id, iface: "eth0", cidr: "192.168.1.2/24"),
                              .setDhcpServer(node: id, config: suggestedDhcpConfig(cidr: "192.168.1.2/24"))]
        case .dns?: cmds += [.setIp(node: id, iface: "eth0", cidr: "192.168.1.3/24"), .setDnsServer(node: id, records: [])]
        case nil: break
        }
```

- [ ] **Step 4: Run** `scripts/test.sh` → 406 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacKit/Topology+Helpers.swift Sources/PacKit/Editor.swift Tests/PacKitTests/DeviceEditorTests.swift
git commit -m "feat(editor): Server DNS and Server DHCP presets"
```

### Task 4: Palette sections, presets on the canvas, M10 selftest

**Files:**
- Modify: `Sources/PacTrack/PaletteView.swift`
- Modify: `Sources/PacTrack/CanvasView.swift` (drop destination, `paneMenu`)
- Modify: `Sources/PacTrack/SelfTest.swift` (palette checks, `m10Scenario`, `render(height:)`)

**Interfaces:**
- Consumes: Task 3's `ServerPreset`, `Editor.addDevice(_:at:preset:)`.
- Produces: `struct PaletteItem: Hashable { let kind: DeviceKind; var preset: ServerPreset? = nil; var label: String; var payload: String; init?(payload: String) }`; `PaletteView.groups(matching:) -> [(String, [PaletteItem])]`.

- [ ] **Step 1: Selftest first** — in `scenario`, replace the `rou` check with the new type and add:

```swift
        if PaletteView.groups(matching: "rou").map(\.1) != [[PaletteItem(kind: .router)]] { failures.append("palette search") }
        if PaletteView.groups(matching: "stamp").map(\.1) != [[PaletteItem(kind: .printer)]] { failures.append("palette search: printer") }
        if PaletteView.groups(matching: "server").map(\.0) != ["Server"] || PaletteView.groups(matching: "server").first?.1.count != 3 {
            failures.append("palette search: servers")
        }
        if PaletteItem(payload: "server-dhcp") != PaletteItem(kind: .server, preset: .dhcp) || PaletteItem(payload: "tv")?.label != "Smart TV" {
            failures.append("palette payloads")
        }
```
and `failures += await m10Scenario(output: output)` after `ipv6ServicesScenario`, with:

```swift
    /// M10 (spec M10 §1): the lab of the new devices as dropped; images of the lab, the printer and the palette in a short window.
    private static func m10Scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.server, at: Pos(x: 340, y: 360), preset: .dhcp)
        await editor.addDevice(.tv, at: Pos(x: 490, y: 380))
        await editor.addDevice(.printer, at: Pos(x: 640, y: 380))
        await editor.addDevice(.pc, at: Pos(x: 790, y: 360))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        for name in ["SRV1", "TV1", "PRN1", "PC1"] { await editor.connect(id("SW1"), id(name)) }
        await editor.edit(.setIp(node: id("PRN1"), iface: "eth0", cidr: "192.168.1.50/24"))
        await editor.edit(.setIfaceMode(node: id("PC1"), iface: "eth0", mode: .dhcp))
        for _ in 0..<610 { await editor.tick(wallMs: 100) }
        let ips = Set(["TV1", "PC1"].map { name in editor.snapshot.nodes.first { $0.name == name }?.ifaces.first?.cidr })
        if ips != ["192.168.1.100/24", "192.168.1.101/24"] { failures.append("M10 leases \(ips)") }
        await editor.startTraffic(id("PC1"), target: "192.168.1.50", kind: .tcp, amount: "100000", seconds: "")
        for _ in 0..<20 { await editor.tick(wallMs: 100) }
        if editor.snapshot.apps.last?.lines.last != "iperf Done." { failures.append("M10 print job \(editor.snapshot.apps.last?.lines ?? [])") }
        editor.select(.node(id("PRN1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m10-lab")) { failures.append("could not write the M10 lab image") }
        editor.select(.node(id("TV1")))
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m10-tv")) { failures.append("could not write the M10 TV image") }
        // The minimum window (640 pt) less the toolbar: the palette scrolls.
        if !render(editor, to: sibling(output, "m10-palette-short"), height: 588) { failures.append("could not write the short palette image") }
        return failures
    }
```
`render`: `static func render(_ editor: Editor, to path: String, height: CGFloat = 860) -> Bool` with `NSSize(width: 1400, height: height)`.

- [ ] **Step 2: Run** `scripts/selftest.sh build/selftest.png` → build error (`PaletteItem` unknown, `preset:` exists since Task 3).

- [ ] **Step 3: Implement** `PaletteView.swift`:

```swift
/// One palette entry: a device kind, or a server preset (spec M10 §3).
struct PaletteItem: Hashable {
    let kind: DeviceKind
    var preset: ServerPreset? = nil

    var label: String { preset?.label ?? kind.label }
    /// What a drag carries.
    var payload: String { preset?.rawValue ?? kind.rawValue }
}

extension PaletteItem {
    init?(payload: String) {
        if let preset = ServerPreset(rawValue: payload) {
            self.init(kind: .server, preset: preset)
        } else if let kind = DeviceKind(rawValue: payload) {
            self.init(kind: kind)
        } else {
            return nil
        }
    }
}
```
`all`:
```swift
    private static let all: [(String, [PaletteItem])] = [
        ("Rete", [.router, .switch, .hub, .cloud].map { PaletteItem(kind: $0) }),
        ("Host", [.pc, .laptop, .printer, .tv].map { PaletteItem(kind: $0) }),
        ("Server", [PaletteItem(kind: .server), PaletteItem(kind: .server, preset: .dns), PaletteItem(kind: .server, preset: .dhcp)]),
    ]
```
`groups(matching:)` returns `[(String, [PaletteItem])]` (same body). In `body`: the search field stays first; the device groups and the cables go in a `ScrollView { VStack(alignment: .leading, spacing: 12) { … } }`; the `Spacer()` goes (the scroll view fills); the hint stays last. Rows: `Label(item.label, systemImage: item.kind.symbol)`, `.draggable(item.payload)`, `.accessibilityIdentifier("palette-\(item.payload)")`, `ForEach(items, id: \.self)`.

`CanvasView.swift` drop:
```swift
                guard let item = items.first.flatMap(PaletteItem.init(payload:)) else { return false }
                Task { await editor.addDevice(item.kind, at: editor.aligned(toWorld(location)), preset: item.preset) }
```
`paneMenu`:
```swift
            ForEach(PaletteView.groups(matching: "").flatMap(\.1), id: \.self) { item in
                Button {
                    let at = editor.aligned(toWorld(menuPoint))
                    Task { await editor.addDevice(item.kind, at: at, preset: item.preset) }
                } label: { Label(item.label, systemImage: item.kind.symbol) }
            }
```

- [ ] **Step 4: Run** `scripts/test.sh && scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m10-lab.png` (palette sections Rete/Host/Server/Cavi, no wrap or cut; the four new devices with their icons; PRN1 Servizi shows only the sink, on), `build/selftest-m10-tv.png` (TV1 eth0 DHCP 192.168.1.10x), `build/selftest-m10-palette-short.png` (the list cut by the scroll view, search on top, hint at the bottom). Fix what the images show and record it.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacTrack/PaletteView.swift Sources/PacTrack/CanvasView.swift Sources/PacTrack/SelfTest.swift
git commit -m "feat(ui): palette sections Rete, Host and Server with the presets, scrolling; M10 selftest images"
```

### Task 5: Manual checks and README

**Files:**
- Create: `docs/manual-checks/m10.md` (Italian, the format of `docs/manual-checks/m9b.md`)
- Modify: `README.md` ("Cosa fa → Dispositivi")

- [ ] **Step 1:** Write the checklist: the spec lab (§1) by hand; palette sections and search (`stamp`, `tv`, `server`, `dhcp`); drag of each new entry and the canvas menu; Servizi of a printer (sink only, off/on); TV in DHCP; presets' addresses and pool, one Cmd+Z; Duplica of a printer and of a Server DHCP (sink kept, pool not); save/reopen; an M9 file opens unchanged; export PNG with the new icons; short window: the palette scrolls.
- [ ] **Step 2:** README bullet:
  `- **Dispositivi**: PC, laptop, stampante (riceve il traffico del generatore), Smart TV (in DHCP), server (anche già pronti come server DNS o DHCP), router, switch (8, 24 o 48 porte), hub e Cloud/ISP, un router con un'uscita "Internet" simulata che risponde a ping e fa da DNS pubblico.`
- [ ] **Step 3:** `scripts/test.sh | tail -1 && scripts/selftest.sh build/selftest.png` → SELFTEST OK.
- [ ] **Step 4: Commit**

```bash
git add docs/manual-checks/m10.md README.md
git commit -m "docs: M10 manual checklist and the new devices in the README"
```
