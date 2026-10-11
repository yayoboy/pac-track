# M12 — Home devices: DSL modem, NAS, console, IoT (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Six new palette entries in a new *Casa* section that work as soon as they are dropped (spec M12 §1–§5): *Modem DSL* (a two-port bridge whose line port runs at VDSL2 100/20 Mb/s), *NAS* (a host with the sink, in DHCP), *Console* (a host in DHCP with the optional Wi-Fi card), *Lampadina smart*, *Termostato*, *Smart speaker* (Wi-Fi-only hosts in DHCP).

**Architecture:**
- Six `DeviceKind` cases on a new line of the enum (`modem, nas, console, smartBulb, thermostat, smartSpeaker`): additive, so the merge with M11b (which appends `homeRouter`) is a two-line union.
- Engine: `Modem` (new file `Devices/Modem.swift`) repeats frames between `dsl0` and `eth0` like a two-port hub. `Interface.sync` holds a DSL port's sync rates; `Link.startTx` serialises at `min(cable, sender's up, receiver's down)`. NAS, console and IoT are `Host`s (IoT with `wifi: true`); the runtime admits the sink on `nas` and Wi-Fi on the console (both cards) and the IoT kinds (Wi-Fi only).
- PacKit: labels, prefixes, `isHost`/`hasIp`, inspector tabs (new lines that reuse the printer's, PC's and hub's lists); `Editor.addDeviceNow` defaults; `firstFreeIface(_:toward:)` picks a modem's port by the peer; `syncLabel`/`cableRate` for the canvas and the Porte tab.
- PacTrack: a *Casa* palette section, symbols, the NAS's Servizi (sink only), the console's card picker, the modem's line under `dsl0`, the DSL cable label; M12 selftest.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM, Command Line Tools only — no Xcode.

**Spec:** `docs/superpowers/specs/2026-10-11-m12-home-devices-design.md`. It extends the main spec (rev. 2) and M7–M11.

Conventions: `docs/superpowers/plans/2026-10-11-m10-host-devices.md`; ledger `.superpowers/sdd/2026-10-11-m12-home-devices/progress.md`.

## Global Constraints

- **Running commands.** Every `swift`/`scripts/*.sh` command runs outside the sandbox. Unit tests only via `scripts/test.sh`; end-to-end `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`. Baseline: `✔ Test run with 439 tests in 58 suites passed`.
- **Git.** Worktree `wt-m12`, branch `m12/home-devices` (from `m11/wifi` at f1b5480); never switch branches, never push, no PRs. One conventional commit per task with the session trailer.
- **Merge with M11b.** M11b (router Wi-Fi domestico, WPA2-PSK) is developed in parallel on `m11/wifi`. Edits to shared spots (`DeviceKind`, `create`, `label`/`namePrefix`/`symbol`/`inspectorTabs`, palette sections, selftest list, README) are new lines where possible.
- **Engine rules.** The Sim owns its nodes; node→sim is `unowned`. Never store `SimTimer`s. The UI holds only `Snapshot` values and string ids. Deterministic iteration order. Tests keep the `Sim` alive.
- **`.ptk`.** `Topology.version` stays `1`; new kind raw values only, no new keys.
- **Copy and style.** UI copy Italian (`Modem DSL`, `NAS`, `Console`, `Lampadina smart`, `Termostato`, `Smart speaker`, section `Casa`); engine errors English; code, comments, tests, commits English.
- **Ponytail/YAGNI.** No profile picker, no PPPoE, no protocols for NAS or IoT, nothing for M11b.

## Review Focus

1. **The line rate.** Upstream (frames `dsl0` sends) at 20 Mb/s, downstream (frames `dsl0` receives) at 100 Mb/s, a slower cable wins; nothing else changes on cables without a modem. Pinned by `aModemLineSendsAt20AndReceivesAt100Mbps` and the full `LinkTests` suite.
2. **Port choice.** `dsl0` toward a Cloud/ISP, `eth0` otherwise, the other port when that one is taken; in either cabling order. Pinned by `aModemFacesTheCloudWithDsl0InEitherOrder`.
3. **Defaults survive saving and undo.** NAS sink + DHCP, console DHCP, IoT SSID + DHCP, each one undo step, round-trip. Pinned by `homeDevicesArriveWithTheirDefaultsInOneStep`.
4. **Gating.** Sink only on server, printer, NAS; Wi-Fi card swap on PC, laptop, console; IoT Wi-Fi only. Pinned by `nasConsoleAndIotAreHosts`.
5. **The spec lab as dropped** and **the palette at selftest size** (23 entries, 6 headers): pinned by `theHomeLabWorksAsDropped` and the M12 selftest images, read by eye.

## Rulings (where the spec is silent)

- **Kinds on a new enum line**, raw values `modem`, `nas`, `console`, `smartBulb`, `thermostat`, `smartSpeaker`. Why: the merge with M11b. Cost if wrong: none.
- **Prefixes** `MODEM`, `NAS`, `CONSOLE`, `LAMP`, `THERM`, `SPK`. Cost if wrong: a name.
- **Symbols** `phone.connection` (DSL rides the phone line), `externaldrive.connected.to.line.below`, `gamecontroller`, `lightbulb`, `thermometer.medium`, `homepod` (the precedent is `ipad`/`iphone`); all exist on macOS 15 (checked with `NSImage(systemSymbolName:)`). Cost if wrong: an icon.
- **`Interface.sync`** (a `(down:up:)` tuple) instead of a `Modem` check in `Link`: the link stays device-agnostic. Cost if wrong: one property.
- **`firstFreeIface(_:toward:)`** gains an optional peer, so existing callers and tests keep compiling. Cost if wrong: none.
- **Palette alias** `Casa: "iot home"`. Cost if wrong: a search word.

## Spec coverage

| M12 spec | Task |
|---|---|
| §2 modem engine (bridge, sync rates), §3–§5 kinds and gating, labels, names, tabs, icons | 1 |
| §2 port choice and line label, §3–§5 defaults, §7 round-trip, §1 lab | 2 |
| §6 palette, §2 canvas label and Porte, §9 selftest | 3 |
| manual checks, README | 4 |

---

### Task 1: Kinds, the modem and the line rate

**Files:**
- Modify: `Sources/PacEngine/Runtime/Protocol.swift` (`DeviceKind`), `Sources/PacEngine/Runtime/Runtime.swift` (`create`, `.setSink`, `.setStation`), `Sources/PacEngine/Node.swift` (`Interface.sync`), `Sources/PacEngine/Link.swift` (`startTx`)
- Create: `Sources/PacEngine/Devices/Modem.swift`
- Modify: `Sources/PacKit/Topology+Helpers.swift` (`label`, `namePrefix`, `hasIp`, `isHost`, `inspectorTabs`), `Sources/PacTrack/Theme.swift`, `Sources/PacTrack/ServicesTab.swift`, `Sources/PacTrack/WifiTab.swift`
- Test: `Tests/PacEngineTests/HomeDevicesTests.swift` (new), `Tests/PacKitTests/HelpersTests.swift`

- [ ] **Step 1: failing tests.** Engine suite `HomeDevicesTests`:
  - `aModemRepeatsFramesBetweenItsTwoPorts`: Runtime, PC1 (10.0.0.1/24) — MODEM1 `eth0`, MODEM1 `dsl0` — PC2 (10.0.0.2/24); ifaces `["dsl0", "eth0"]`, no IP (`setIp` on the modem throws); ping 4/4.
  - `aModemLineSendsAt20AndReceivesAt100Mbps`: `Probe` A on `eth0`, B on `dsl0`; one ARP frame each way (84 B on the wire): B gets A's at 1172 + 33600 + 500 = 35272 ns; A gets B's at 6720 + 500 + 1172 = 8392 ns. With a 10 Mb/s cable on `dsl0` both directions take 67200 ns.
  - `nasConsoleAndIotAreHosts`: NAS `eth0` and the sink; console `eth0`, swaps to `wlan0` and back; bulb, thermostat, speaker `wlan0` only ("LAMP1 has only a Wi-Fi card"); sink refused on console and bulb ("cannot run a traffic sink"); DHCP server refused on the NAS.
  - `HelpersTests.homeDevicesHaveItalianNamesPrefixesAndTabs`: labels, prefixes, `isHost` (all but the modem), `!modem.hasIp`, tabs (`modem` → Porte; `nas` = printer's; console and IoT = PC's).
- [ ] **Step 2:** `scripts/test.sh` → build error "type DeviceKind has no member modem".
- [ ] **Step 3: implement.**

```swift
// Protocol.swift, inside DeviceKind (a new line)
    case modem, nas, console, smartBulb, thermostat, smartSpeaker

// Node.swift, Interface
    /// A DSL port's sync rates (spec M12 §2): it sends at `up` and receives at `down`, whatever the cable.
    var sync: (down: Double, up: Double)?

// Link.swift, startTx
        // A DSL port sends at its upstream and receives at its downstream sync rate (spec M12 §2); a slower cable wins.
        let bps = min(opts.bandwidthBps, from.sync?.up ?? .infinity, peer(from).sync?.down ?? .infinity)

// Devices/Modem.swift
public let VDSL2_SYNC = (down: 100e6, up: 20e6)
final class Modem: Node { /* dsl0 (sync = VDSL2_SYNC) and eth0; receive repeats to the other port like Hub */ }

// Runtime.create (new lines)
        case .nas, .console: Host(sim: sim, id: id)
        case .smartBulb, .thermostat, .smartSpeaker: Host(sim: sim, id: id, wifi: true)
        case .modem: Modem(sim: sim, id: id)
```
  Runtime: `.setSink` admits `.nas`; `.setStation` admits console and IoT, the Ethernet card (nil) only on PC, laptop, console. Helpers/Theme/ServicesTab (`printer || nas`)/WifiTab (card picker on console).
- [ ] **Step 4:** `scripts/test.sh` green (443 tests). Commit `feat(engine): M12 home device kinds and a DSL modem with VDSL2 sync rates`.

### Task 2: Defaults, the modem's ports and the line label

**Files:**
- Modify: `Sources/PacKit/Editor.swift` (`addDeviceNow`, `connectNow`), `Sources/PacKit/Topology+Helpers.swift` (`firstFreeIface`, `syncLabel`, `cableRate`)
- Test: `Tests/PacKitTests/HomeDevicesEditorTests.swift` (new)

- [ ] **Step 1: failing tests** (`HomeDevicesEditorTests`, `@MainActor`, `Editor(client: Simulation())`):
  - `homeDevicesArriveWithTheirDefaultsInOneStep`: modem (no address, ifaces `dsl0`, `eth0`), NAS (sink, DHCP), console (DHCP, `eth0`), bulb/thermostat/speaker (`wlan0` DHCP, SSID `pac-track`); names `MODEM1`, `NAS1`, `CONSOLE1`, `LAMP1`, `THERM1`, `SPK1`; round-trip through `ProjectFile`; six undos empty the canvas; reopened equal.
  - `aModemFacesTheCloudWithDsl0InEitherOrder`: router first then cloud → R1 on `eth0`, ISP1 on `dsl0`; on a second modem cloud first then router → same; a third cable to a full modem → "MODEM1 has no free port"; a modem between two routers takes `eth0` then `dsl0`. `cableRate` reads `100/20 Mb/s` on the DSL cable and `1 Gb/s` on the Ethernet one; with a 10 Mb/s DSL cable `10/10 Mb/s`.
  - `theHomeLabWorksAsDropped`: the spec §1 lab; at 61 s five leases in .100–.199; TCP from CONSOLE1 to NAS1 → `iperf Done.`; ping from CONSOLE1 to `www.example.com` → 0% loss.
- [ ] **Step 2:** red (defaults missing, wrong ports, `cableRate` missing).
- [ ] **Step 3: implement.** `addDeviceNow`: NAS sink + `eth0` DHCP, console `eth0` DHCP, IoT with the tablets' line. `firstFreeIface(_ node:, toward peer: NodeView? = nil)`: on a modem prefer `dsl0` iff the peer is a cloud, else the other free port. `connectNow` passes the peer. `syncLabel(down:up:)` → `"100/20 Mb/s"`; `cableRate(link, in:)`.
- [ ] **Step 4:** green. Commit `feat(editor): M12 defaults, the modem's ports by peer and the DSL line label`.

### Task 3: Palette, canvas, Porte and the M12 selftest

**Files:** `Sources/PacTrack/PaletteView.swift` (section Casa, alias), `Sources/PacTrack/CanvasView.swift` (cable label via `cableRate`), `Sources/PacTrack/InspectorView.swift` (`ports`: "VDSL2 · 100/20 Mb/s" under a modem's `dsl0`), `Sources/PacTrack/SelfTest.swift` (sections list, search checks, `m12Scenario`).

- [ ] **Step 1:** selftest first: palette sections `[… "Wireless", "Casa"]`, `casa`/`iot` find the six, `smart` finds Smart TV, Lampadina smart, Smart speaker, `dsl` finds the modem; `m12Scenario` builds the spec lab and checks leases, `iperf Done.`, the ping, the DSL cable label. → red.
- [ ] **Step 2:** implement; images `m12-lab` (MODEM1 Porte), `m12-nas` (Servizi), `m12-iot` (LAMP1 Wi-Fi), `m12-console` (CONSOLE1 Wi-Fi, card picker), `m12-palette` (palette scrolled to Casa is not possible offscreen: the lab image shows the top, `m12-palette-search` the section by search `casa`), `m12-palette-short` (588 pt).
- [ ] **Step 3:** `SELFTEST OK`; read every image: nothing clipped, wrapped or truncated. Commit `feat(ui): M12 Casa palette section, the DSL line on the canvas and the M12 selftest`.

### Task 4: Manual checks and README

- [ ] `docs/manual-checks/m12.md` (Italian, like `m10.md`); README *Dispositivi* bullet and *Fuori perimetro*. Commit `docs: M12 manual checks and README`.
