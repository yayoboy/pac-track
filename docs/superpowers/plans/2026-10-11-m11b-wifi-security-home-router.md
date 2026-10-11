# M11b — Wi-Fi range, WPA2-PSK and the home Wi-Fi router (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, one task at a time) with superpowers:test-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** spec M11 §1 *Successo M11b*: a *Router Wi-Fi domestico* (HR1) with its Internet port on the Cloud/ISP and the network `casa` in WPA2-PSK; a tablet with the right password associates, runs the 4-way handshake and takes its address from HR1's DHCP; with a wrong password message 2 fails the MIC check and HR1 deauthenticates it. Moving the tablet out of HR1's range drops the association; moving it back brings it back, at a rate that depends on the distance.

**Architecture:**
- **Range (engine):** `Node.pos` (a `Pos`, (0, 0) until told), set by the new command `.move(node:to:)` and by `.load`. `dot11Signal(a, b)` gives dBm or nil beyond `WIFI_RANGE` (300 pt); `dot11Rate(signal:)` the 802.11g rate (Table 17-18). `Medium` delivers a frame only to radios in range of its sender. `Dot11Header.rate` carries the unicast data rate the transmitter picked; `dot11Airtime` and the inspector read it (ACK at the highest basic rate not above). A scan keeps the strongest Probe Response. `Sim.rangeChanged()` (after a move) restarts every station whose access point is now out of range. Views: `StationView.signal/rate`, `AssociationRow.signal/rate`.
- **WPA2-PSK (engine):** `ApConfig.passphrase` / `StationConfig.passphrase` (`String?`, synthesized `Codable` decodes a missing key as nil). `Dot11Mgmt.probeResponse` and `.associationRequest` gain `rsn`. New `L3.eapol(EapolKey)` (EtherType 0x888E) and `eapolMic` (FNV-1a fingerprint). `ApRadio.Client` gains the handshake state (`authorized`, ANonce, attempts); `StationRadio` gains states `.handshake` and `.wrongPassword`. `Dot11Header.protected` (+16 B CCMP). Drop reason `mic-failure`.
- **Home router (engine):** `HomeRouter: Router` with `Internet`, `LAN1`–`LAN4`, `WLAN` (an `ApRadio`) and the bridge interface `LAN` (`Interface.bridge`): a learning bridge over the LAN ports and the radio whose own interface feeds the IP stack (NAT, DHCP server, ARP… unchanged). `Interface.send`, `lineUp`, `reach`, `segmentPeers` and `Link` learn the bridge interface. The DHCP client moves from `Host` to `IpNode` so the Internet port can use it; the DHCP server relays the WAN-learned DNS on a home router when its pool has none.
- **PacKit/UI:** kind `homeRouter` ("Router Wi-Fi", `HR`, icon `wifi.router`, Wireless section); editor presets (home router; Cloud DHCP pool); cable to the Internet port toward a Cloud/router; positions synced to the engine on add, drag end, paste and undo; Wi-Fi tab security and password, signal line; Interfacce/Servizi/Tabelle for the home router; range circles and rate labels on the canvas; M11b selftest images.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM, Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-10-11-m11-wifi-design.md` §1 (success M11b) and §8 with its *Decisione* sub-bullets (written with this plan). Conventions: the M11a plan and ledger.

## Global Constraints

- **Running commands.** Every `swift`/`scripts/*.sh` command runs outside the sandbox. Unit tests only via `scripts/test.sh` (`--filter <Suite>` for one suite). `swift build --product PacTrack` builds after every task. `scripts/selftest.sh build/selftest.png` prints `SELFTEST OK`. Baseline: `✔ Test run with 436 tests in 58 suites passed` (M11a ledger, after d7d1093; the merged ux branch may have added some — record the real baseline first).
- **Git.** In place on `m11/wifi`; no branch switches, no push, no PR. One conventional commit per task with the session trailer.
- **TDD.** Every new behaviour starts with a failing test (RED recorded in the ledger `.superpowers/sdd/2026-10-11-m11b-wifi-security-home-router/progress.md`).
- **Engine rules.** Sim owns nodes, node→sim `unowned`; no stored `SimTimer` (generation/identity guard in callbacks); UI holds snapshots and ids; removed nodes stay alive while frames fly; deterministic order (no dictionary iteration where observable; radios in device order); no randomness beyond `sim.rng`; overflow guarded (replay counter, sequence numbers); tests keep the Sim alive.
- **Compatibility.** Open networks and devices at the origin behave exactly as in M11a: every M11a timing test passes unchanged except where a pattern match must name the new `rsn` field. M1–M11a files open unchanged (`passphrase` keys absent → nil; positions already saved).
- **Copy.** UI Italian; engine errors English; code, comments, commits English. Colours only via `Theme`. Never delete existing lines or comments a task does not replace.
- **YAGNI.** No per-AP range or transmit power, no roaming while associated, no real cryptography, no DNS forwarder, no WPA3/enterprise, no live range updates during a drag.

## Rulings (where the spec is silent)

- `WIFI_RANGE = 300` pt; signal `-30 - 52·d/R` rounded to the nearest dBm; at d = 0 → −30. Cost if wrong: one constant.
- `Dot11Header.rate` defaults to 54 so headers built without it (M11a tests) keep 54 Mb/s. Management and group frames always go at 6 whatever the field says; the radio writes the rate it used (6) into those headers too, so the inspector reads one place. Cost if wrong: none.
- ACK rate = highest basic rate (6, 12, 24) not above the frame's, replacing `min(rate, 24)` (equal for 6 and 54, the only rates M11a used). Cost if wrong: none.
- A station keeps a Probe Response only if stronger than the one it holds (strict `>`): ties keep the first, so M11a's order stays. Cost if wrong: none.
- `.move` is not an undo step of its own: the editor's existing move history (`moveStart`/`moveEnd`) is; undoing a move sends `.move` back. `Editor.moveEnd()` becomes `async`. Cost if wrong: the drag gesture wraps it in a `Task`.
- EAPOL Key Information as hostapd/wpa_supplicant send it with HMAC-SHA1/AES (version 2): 0x008a, 0x010a, 0x13ca, 0x030a. Replay counter starts at 1 per association and goes up with each message 1 or 3. Key length 16 in messages 1 and 3, 0 in 2 and 4. MIC: two FNV-1a 64-bit passes over passphrase, SSID, ANonce, SNonce and the message number → 16 B. Nonces shown as the first 8 bytes in hex and "…".
- The AP sends message 3 right after a valid message 2 and authorizes the station at message 4; the 1 s timer only repeats message 1 while no valid message 2 came. A station has no handshake timer: the AP's Deauthentication (reason 15), the AP going away or a configuration change end it.
- Frames to or from a station not yet authorized: the station sends nothing but EAPOL (its line is down); the AP treats it as not associated for the bridge (`associated(_:)` and `peers` count authorized stations only) and drops other data from it as `not-associated`.
- Home router bridge: frames from the router itself (`LAN`) go to the learned port, to the air if the destination is an authorized station or a group, else flood the LAN ports; frames from a LAN port or the air go to the IP stack when addressed to `LAN`'s MAC or a group, then as above (never back out of the port they came in, except the air relaying a station's frame From DS). `noteL2` for loop warnings.
- `HomeRouter.setIp` refuses a LAN port or the radio: "LAN1 is a port of the LAN bridge"; `.setIpv6` likewise. `Link` refuses `LAN`: "Cannot cable a bridge interface". `.setIfaceMode` on a home router only on `Internet`.
- The DHCP client move: `IpNode.dhcp` + `IpNode.setDhcp(_:on:)`; `Host.setDhcp(_:)` stays as the one-card shortcut. Reset/powerOn/linkChanged logic moves with it unchanged.
- Kind checks: DHCP server, NAT and firewall accept `homeRouter`; RIP, OSPF, subinterfaces, IPv6 routing and RDNSS stay router-only.
- Cloud preset: `DhcpConfig(start: "203.0.113.100", end: "203.0.113.199", gateway: "203.0.113.1", dns: "203.0.113.1")`; the Servizi text of the Cloud mentions it.
- Canvas: one light circle (radius `WIFI_RANGE`) around each access point and home router, under the cables; the dashed line carries the station's rate ("36 Mb/s") at its midpoint. Dashed line also during the handshake (EAPOL frames fly along it).

## Review Focus

1. **M11a unchanged** at the origin and on open networks (WifiTests timings, RuntimeWifiTests, WifiEditorTests).
2. **Handshake edges:** wrong password (4 × msg 1, deauth 15 at 4 s, "Password errata", no rescan), config change mid-handshake, AP off or out of range mid-handshake, no data before msg 4, Protected only after.
3. **Bridge:** no loops or echoes (a frame never goes back out of its port; group frames from a station relayed once on the air), `segmentPeers` across LAN ports and the air (duplicate check), NAT from `LAN` to `Internet`, DHCP on `LAN` only.
4. **Determinism:** same seed → same nonces, MICs, event log.
5. **What the learner reads:** EAPOL layers and info, Protected flag, *Informazioni radio*, status lines, Tabelle rows, range circles — selftest images read by eye.

## Tasks

### Task 1: Range — positions, signal, rate, hearing, strongest AP, drop on move

Files: `Sources/PacEngine/Node.swift`, `Devices/Radio.swift`, `PDU.swift`, `Sim.swift`, `Runtime/Protocol.swift`, `Runtime/Runtime.swift`, `Runtime/EventViews.swift`; tests `Tests/PacEngineTests/WifiRangeTests.swift` (new), `Dot11PduTests.swift`.

- [ ] RED tests (`WifiRangeTests`):
  - `signalAndRateFallWithDistance`: `dot11Signal` at 0, 150, 200, 270, 300, 301 pt → −30, −56, −65, −77, −82, nil; `dot11Rate` −65 → 54, −66 → 48, −70 → 36, −74 → 24, −77 → 18, −79 → 12, −81 → 9, −82 → 6.
  - `aStationOutOfRangeNeverHearsTheAccessPoint`: AP1 at (0,0), TAB1 at (400,0) → after 6 s `notFound`, no Probe Response logged.
  - `unicastDataGoesAtTheStationsRate`: TAB1 at 270 pt (18 Mb/s): a ping's frames carry `air.rate == 18` both ways; airtime = DIFS + backoff + PPDU at 18 + SIFS + ACK at 12; mgmt frames 6.
  - `theStationPicksTheStrongestAccessPoint`: AP1 (6) at 250 pt, AP2 (11) at 50 pt, same SSID → associated to AP2 although AP1 answered first.
  - `movingOutOfRangeDropsTheAssociationAndComingBackRestoresIt` (Runtime): `.move` TAB1 beyond 300 → not associated at once, AP has no clients, no Deauthentication; move back → associated within 5.1 s.
  - `stationAndAccessPointViewsShowSignalAndRate` (Runtime snapshot) and `positionsComeBackFromTheProjectFile` (load sets `pos`).
  - Dot11PduTests: ACK rate after 18 Mb/s is 12; inspector layer *Informazioni radio* (Velocità, Tempo in aria).
- [ ] GREEN: `Node.pos`; `WIFI_RANGE`, `DOT11_SENSITIVITY`, `dot11Signal(_:_:)`, `dot11Rate(signal:)` in Radio.swift; `Medium.start` filters `dot11Signal(radio.iface.node, r.iface.node) != nil`; `Dot11Header.rate`; `dot11Airtime` uses it; `Radio.transmit(_:_:rate:)`; `StationRadio.send` and `ApRadio.send` pick the rate; strongest Probe Response; `Sim.rangeChanged()`; `Command.move(node:to:)`; `Runtime.load` sets `pos`; views.
- [ ] Full suite green; commit `feat(engine): M11b range — signal, rate and association follow the distance`.

### Task 2: WPA2-PSK and the 4-way handshake

Files: `Runtime/Protocol.swift` (configs, `StationState`), `PDU.swift` (EAPOL, RSN, Protected), `Devices/Radio.swift`, `Events.swift` (`micFailure`), `L3/IpNode.swift` (switch), `Runtime/EventViews.swift`; tests `Tests/PacEngineTests/Wpa2Tests.swift` (new), `Dot11PduTests.swift`, `WifiTests.swift` (pattern updates only).

- [ ] RED tests (`Wpa2Tests`):
  - `passphrasesAreEightToSixtyThreePrintableCharacters` (AP refuses 7, 64, "è"; nil is open).
  - `theRightPasswordRunsTheFourWayHandshakeThenDataFlows`: log of EAPOL 1–4 after the Association Response (sizes 99/121/155/99 + 32), RSN in Probe Response and Association Request, station `.handshake` with line down until msg 4, then `.associated`, DHCP starts; data frames Protected and 16 B longer; EAPOL not Protected.
  - `aWrongPasswordFailsTheMicAndEndsInADeauthentication`: msg 1 at 0/1/2/3 s, each msg 2 dropped `mic-failure`, Deauthentication reason 15 at 4 s, station `.wrongPassword`, no Probe Request afterwards; a new password restarts and succeeds.
  - `aStationWithAPasswordJoinsAnOpenNetworkWithoutHandshake`.
  - `sameSeedSameNoncesAndMics` (two runs equal logs).
  - `changingTheAccessPointPasswordDeauthenticatesTheStations`.
  - Codable: an M11a `ApConfig`/`StationConfig` JSON decodes with nil passphrase.
  - Dot11PduTests: EAPOL-Key layers and info "EAPOL-Key, messaggio 1 di 4"; Flag "0x41 (To DS, Protected)"; RSN field.
- [ ] GREEN as the rulings say.
- [ ] Full suite green; commit `feat(engine): M11b WPA2-PSK with the 4-way handshake`.

### Task 3: Home Wi-Fi router in the engine

Files: `Devices/HomeRouter.swift` (new), `Node.swift`, `Link.swift`, `L3/Rip.swift` (`lineUp`), `L3/IpNode.swift` + `Devices/Host.swift` (DHCP client move), `L3/DhcpServer.swift` (DNS relay), `Runtime/Protocol.swift` (`DeviceKind.homeRouter`), `Runtime/Runtime.swift`; tests `Tests/PacEngineTests/HomeRouterTests.swift` (new).

- [ ] RED tests (`HomeRouterTests`):
  - `aHomeRouterHasAnInternetPortFourLanPortsARadioAndTheLanBridge` (names, `LAN` takes no cable, LAN ports refuse an address).
  - `lanPortsAndTheAirAreOneSegment`: PC on LAN1, PC on LAN2, TAB on the air, 192.168.0.1 on `LAN`: pings across all; `segmentPeers` of `LAN` lists them; a duplicate on LAN3 is refused.
  - `theBridgeLearnsAndNeverEchoes`: a unicast after learning goes out of one port only; a broadcast from LAN1 reaches LAN2 and the air once, not LAN1; a station's broadcast goes to the LAN ports and once back on the air.
  - `theInternetPortTakesItsAddressFromTheIspAndNatsTheLan` (Cloud with DHCP pool, HR WAN in DHCP, LAN client pings 198.51.100.10 → NAT entry).
  - `theDhcpServerPassesOnTheDnsLearnedOnTheInternetPort`.
  - `noSpanningTreeNoBpdusAndTaggedFramesDropped`; `switchedOffItDropsItsStations`.
  - `hostsKeepTheirDhcpClient` (refactor guard: existing DhcpTests stay green).
- [ ] GREEN; commit `feat(engine): M11b home Wi-Fi router — LAN bridge with radio, DHCP on the Internet port`.

### Task 4: PacKit — kind, presets, cables, positions, Wi-Fi texts, the spec lab

Files: `Sources/PacKit/Topology+Helpers.swift`, `Editor.swift`, `EventHelpers.swift`; tests `Tests/PacKitTests/HomeRouterEditorTests.swift` (new), `WifiEditorTests.swift`, `HelpersTests.swift`, existing cloud-default tests.

- [ ] RED: home router defaults in one undo step (LAN 192.168.0.1/24, pool .100–.149 gw .1, NAT LAN→Internet, Internet DHCP); Cloud preset DHCP pool; cable to Internet toward Cloud/router, to LAN1 otherwise; `airLinks` toward `WLAN`; positions reach the engine on add, drag end, undo/redo, paste (association drops when a tablet is dragged out); `wifiStatus` handshake / password errata and signal line; `associationRows` with signal and rate; security texts; the M11b success lab (HR1 + ISP1 + TAB1 with `casa`/password → leased 192.168.0.100, ping 198.51.100.10; wrong password → "Password errata").
- [ ] GREEN; commit `feat(kit): M11b home router presets, positions in the engine, Wi-Fi security texts`.

### Task 5: UI — palette, Wi-Fi tab security, home router inspector, canvas range

Files: `Sources/PacTrack/PaletteView.swift`, `WifiTab.swift`, `InspectorView.swift`, `ServicesTab.swift`, `CanvasView.swift`, `DeviceNodeView.swift` (moveEnd async, icon), `Theme.swift` if a colour is needed.

- [ ] RED: selftest palette check expects *Router Wi-Fi* in WIRELESS (fails first).
- [ ] GREEN; commit `feat(ui): M11b router Wi-Fi in the palette, WPA2 in the Wi-Fi tab, range on the canvas`.

### Task 6: M11b selftest images

Files: `Sources/PacTrack/SelfTest.swift`.

- [ ] Scenario: ISP1 + HR1 (`casa`, WPA2) + TAB1 (right password, near) + PHONE1 (wrong password) + LAPTOP1 near the edge. Checks: TAB1 leased in 192.168.0.100–149 and Protected data; PHONE1 "Password errata"; images `m11b-lab` (range circle, dashed lines with rates), `m11b-eapol` (EAPOL-Key message 2 in the inspector), `m11b-hr` (home router Wi-Fi tab with WPA2-PSK), `m11b-hr-ifaces` (Interfacce), `m11b-hr-tables`, `m11b-station` (status with signal). Read each image by eye.
- [ ] Commit `test(ui): M11b selftest images`.

### Task 7: Manual checks and README

Files: `docs/manual-checks/m11b.md` (new), `README.md`.

- [ ] Italian checklist in the m11a style; README Wi-Fi and Dispositivi bullets; remove the M11b clause from *Fuori perimetro*.
- [ ] Commit `docs: M11b manual checks and README`.

### Final: independent review

- [ ] One opus reviewer in a clean worktree on this branch's range; fix Critical/Important (each RED first); log deferred Minor items; remove the worktree; `scripts/test.sh`, selftest, `scripts/bundle.sh` green.
