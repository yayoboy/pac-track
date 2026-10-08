# M4 — TCP, traffic generator, Metriche (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hosts talk TCP the way the RFCs describe it (three-way handshake with the MSS option and an ISN from the PRNG, seq/ack, a 64 KB receive window, RFC 6298 retransmission with back-off, Reno slow start / congestion avoidance / fast retransmit, FIN and TIME_WAIT, RST), servers run a discard sink, any host runs an iperf3-style TCP or UDP generator against it, and the new **Metriche** tab charts every cable (utilisation, queue, drops per direction) and every flow (goodput, RTT or latency, jitter, loss), one point per 100 ms of simulated time.

**Architecture:** `PacEngine` gains a typed `TcpSegment` (real checksum over the pseudo-header) and a generator datagram as a UDP payload, a per-node `Tcp` layer (`L4/Tcp.swift`: demultiplexing, listening ports, RST generation) with one `TcpConnection` state machine per connection (sequence numbers kept as offsets from each ISN, one lazily re-armed retransmission timer per connection, no stored `SimTimer`), the discard sink on TCP/UDP port 9, and two apps (`TcpFlow`, `UdpFlow`) that measure their own flow (UDP arrivals come back from the sink through a flow id in the datagram, as iperf3 puts its sequence number and timestamp in the payload). Links count busy time and drops per direction. The `Runtime` samples cables and flows at exact 100 ms boundaries inside its run loop (no scheduler timer), keeps the last 600 points and ships them in the `Snapshot`; it adds three commands and the `sink` key in `.ptk`. `PacKit` parses the generator fields and formats metrics; `PacTrack` adds the generator to the App tab, the sink toggle, a TCP connections table, the Metriche panel (Swift Charts) and "Mostra metriche" on cables.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit + Swift Charts (macOS 15), Observation, Swift Testing, SwiftPM — Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2: §5.1 ISN from the PRNG, §5.2 per-direction queues, §5.3 TCP PDU, §5.4 TCP row, §5.5 server sink, §5.6 generator and metrics, §6, §7.1 ④⑤, §7.2 link menu "Mostra metriche", §7.3 TCP colour, §8, §9, §10 — milestone M4). Conventions: `docs/superpowers/plans/2026-10-08-m3-dhcp-dns.md`; rulings ledger style: `.superpowers/sdd/2026-10-08-m3-dhcp-dns/progress.md`.

## Global Constraints

- Run every `swift`/`scripts/*.sh` command **outside the sandbox**; unit tests only via `scripts/test.sh` (bare `swift test` runs zero tests with CLT). End-to-end: `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`.
- Work in place on branch `rewrite/v3`; never switch branches or create worktrees. An M3 fix pass may be touching DHCP/DNS files concurrently: **stage only the files a task lists** (`git add <paths>`, never `git add Sources/...` wholesale) and do not edit `L3/Dhcp*.swift`, `L3/Dns.swift` or their tests.
- The UI never holds engine objects — only `Snapshot` values and string ids.
- Never store `SimTimer`s: TCP's retransmission timer is a deadline plus a generation-checked callback, TIME_WAIT and the generators check their state in the callback. Callbacks stored in engine objects capture apps `weak` (`onChange`, `Sim.flows`). Removed nodes stay alive until the Sim is replaced.
- All randomness (ISN, ephemeral ports) from `sim.rng`, drawn only after the input is validated; never iterate a `Dictionary` on the simulation path or for anything shown in order (`linkSamples` is read by id only).
- Every network change goes through `Editor.edit` (one undo step: the sink); apps and clock through `Editor.run`. Snapshot `version` stays stable while nothing changes.
- `.ptk`: `Topology.version` stays `1`; the new node key `sink` is optional on read (missing ⇒ off). Metrics, TCP connections and flows are never saved.
- Protocol constants: MSS 1460 (536 when the peer sends none), advertised window 65 535 B, initial window min(4·MSS, max(2·MSS, 4380 B)) = 4380 B, initial ssthresh 65 535 B, RTO 1 s initial and minimum / 120 s maximum, 6 retransmissions before "Connection timed out" (SYN: 127 s), TIME_WAIT 60 s, ephemeral ports 32768–60999, discard port 9, generator datagram 1470 B, metrics every 100 ms, 600 points kept.
- User-facing copy Italian; engine error messages and the iperf3-style app output English (as ping/traceroute); code, comments, tests, commits English. Colours only via `Theme` (TCP `#5fb865`).
- Ponytail: nothing for M5/M6 (no NAT, firewall, export); every API below has a consumer in this plan; deliberate shortcuts carry a `ponytail:` comment naming the ceiling.
- Commit trailer (exactly this line, after a blank line):
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

## Review Focus

1. **Traffic aimed at a host without the sink (or at a PC)** → TCP fails at once with "Connection refused" (`[SYN]` answered by `[RST, ACK]`), UDP reports 100 % loss while the target answers ICMP port unreachable; nothing hangs. Pinned: `aClosedPortAnswersTheSynWithARst`, `tcpFlowToAHostWithoutTheSinkIsRefused`, `udpFlowToAHostWithoutTheSinkLosesEverything`.
2. **The server goes away mid-transfer** (powered off, cable pulled, rebooted) → retransmissions at 1, 2, 4 … s, "Connection timed out" after 127 s, or "Connection reset by peer" once it is back and has forgotten the connection; the flow always ends. Pinned: `retransmitsALostSynAfter1SecondDoublingTheTimeoutAndGivesUpAfter127Seconds`, `aServerThatForgotTheConnectionResetsIt`.
3. **The sender is switched off, removed or its flow evicted mid-transfer** → the flow ends with iperf3's interrupt line; an explicit stop resets the sink's end instead of leaving it ESTABLISHED. Pinned: `stoppingATcpFlowResetsTheConnection`, `poweringTheSenderOffEndsItsFlow`.
4. **A UDP rate above the cable's** → the queue sits at its limit, drops are counted on that direction, the report and the flow chart show the loss. Pinned: `udpAboveTheCableRateFillsTheQueueAndTailDrops`.
5. **Simulation-mode step across a long idle stretch, or an undo/reload while flows run** → no freeze (at most 600 points computed), series restart after a reload, a removed cable's series disappears. Pinned: `steppingOverAnIdleHalfDayKeepsOnlyTheLastMinuteOfSamples`, `runsTcpTrafficAndSamplesTheFlowAndEveryCableEvery100ms`.

## Rulings (where the spec is silent)

Each line: ruling — why — cost if wrong.

- The receiver ACKs every segment that carries data or a FIN at once (no delayed ACK) — RFC 5681 permits it, it is the textbook/ns-2 sink and keeps the duplicate-ACK count exact — twice Linux's ACK count on the wire.
- Advertised window fixed at 65 535 B (no window scaling): the sink reads at once and out-of-order data is held without shrinking the offered window (RFC 1122 §4.2.2.16) — fast retransmit's "same window" test (RFC 5681 §2) keeps working — BDPs above 64 KB are window-limited (realistic for a stack without scaling).
- Only the MSS option on SYNs (SYN frame 58 B, not Linux's 74 B); no PSH, SACK, timestamps; Wireshark-style info lines show **absolute** sequence numbers (the spec wants the PRNG's ISN visible; relative numbers need per-connection decoding state) — the spec names MSS only — a later "relative numbers" view would need the ISN per 4-tuple.
- RFC 6298 exactly: SRTT/RTTVAR from one timed segment at a time, Karn's rule, RTO ≥ 1 s, back-off ×2, RTO ≥ 3 s after a lost SYN (5.7); clock granularity G ignored (below the 1 s floor); maximum 120 s and 6 retransmissions as Linux (`TCP_RTO_MAX`, `tcp_syn_retries`) so a dead SYN fails at 127 s — RFC 6298 allows any cap ≥ 60 s and leaves R2 to the host — Windows-like timings would differ.
- Reno per RFC 5681 (IW 4380 B, initial ssthresh 65 535 B, slow start +min(acked, SMSS), avoidance +SMSS²/cwnd per ACK, fast retransmit on the 3rd duplicate, window inflation, deflation on the first new ACK) — the spec says Reno — multiple losses in one window usually end in an RTO (NewReno/SACK would recover).
- TIME_WAIT lasts 60 s (Linux `TCP_TIMEWAIT_LEN`) and a repeated FIN is re-ACKed without restarting it — the spec says FIN/RST only — 4 min would be RFC 793's 2 × MSL.
- The sink closes as soon as it reads the peer's FIN, so its FIN rides on the ACK (three-segment close) and CLOSE_WAIT is never visible; CLOSING (simultaneous close) goes straight to TIME_WAIT — nothing in M4 can close both ends at once — a FIN-first peer would show one segment fewer.
- Payload bytes are zeros: the TCP checksum is computed for real over pseudo-header + header (zeros add nothing) — matches "checksum calcolati realmente" — none.
- The server's "sink/echo" service is the **discard sink only** (RFC 863), TCP and UDP port 9, servers only, saved per node as `sink` like M3's services — the generator is its only client; echo has no consumer — echo added when a lab needs replies.
- The generator mimics iperf3 (`iperf3 -c … -p 9 -n …`, `iperf3 -u … -b … -t …`, its connect/report/`iperf Done.` lines, 1470-byte datagrams, exact constant pacing); the UDP report comes 1 s after the last datagram; a stopped TCP flow aborts with RST (SO_LINGER 0) — the user knows iperf3 — no per-second interval lines.
- Flow metrics: TCP goodput from bytes acknowledged at the sender, delay = SRTT, loss = retransmitted ÷ sent segments; UDP goodput and mean one-way latency of the interval's arrivals, RFC 3550 jitter, live loss from sequence gaps and final loss from sent − received — what iperf3 reports — none.
- Cable metrics per direction: utilisation (a frame counts whole in the interval its serialisation starts, capped at 100 %), queue length at the instant, drops in the interval (full queue, random loss, fault) — spec §5.6 — ±1 frame time per interval.
- Sampling happens at exact 100 ms boundaries inside `Runtime`'s run loop and Simulation step, not as a scheduler timer (an idle network keeps an empty queue, so Simulation step behaves as before); an idle gap longer than 600 points skips the points that would be discarded; metrics ride in the `Snapshot` (no separate `metrics` message from §6) — fewer moving parts — ~600 points × cables compared per snapshot.

---

## File Structure

```
Sources/PacEngine/PDU.swift                  IPPROTO_TCP, TcpFlags, TcpSegment, serialize/makeTcp, TrafficData, UdpPayload.traffic, TRAFFIC_DATAGRAM, PORT_DISCARD
Sources/PacEngine/L4/Tcp.swift               (new) Tcp (listen, demux, RST) and TcpConnection (RFC 793 states, RFC 6298 timer, RFC 5681 Reno)
Sources/PacEngine/L3/IpNode.swift            TCP delivery, sendPacket(src:), reset, discard sink
Sources/PacEngine/Sim.swift                  flows registry (sink → generator)
Sources/PacEngine/Scheduler.swift            runUntil returns the events run, nextTime
Sources/PacEngine/Link.swift                 LinkCounters per direction
Sources/PacEngine/Apps/Traffic.swift         (new) TcpFlow, UdpFlow, SAMPLE_NS, METRICS_HISTORY
Sources/PacEngine/Runtime/Protocol.swift     Proto.tcp, FlowSample, DirectionSample, LinkSample, TcpRow, commands, view fields, TopologyNode.sink
Sources/PacEngine/Runtime/EventViews.swift   TCP info line and PDU layer, generator datagrams
Sources/PacEngine/Runtime/Runtime.swift      traffic apps, sink, 100 ms sampling, snapshot, load
Sources/PacKit/Topology+Helpers.swift        BottomTab, TrafficKind, flowSummary, directionSummary, makeTopology sink
Sources/PacKit/Editor.swift                  bottomTab, startTraffic
Sources/PacTrack/Theme.swift                 TCP colour
Sources/PacTrack/MetricsPanel.swift          (new) Metriche tab (Swift Charts)
Sources/PacTrack/BottomPanel.swift           tab from the Editor, Metriche
Sources/PacTrack/InspectorView.swift         App: traffic generator; Tabelle: TCP connections
Sources/PacTrack/ServicesTab.swift           sink toggle
Sources/PacTrack/CanvasView.swift            "Mostra metriche"
Sources/PacTrack/SelfTest.swift              M4 scenario + two images
Tests/PacEngineTests/{TcpPduTests,TcpTests,TrafficTests,RuntimeTrafficTests}.swift (new)
Tests/PacKitTests/TrafficEditorTests.swift (new), HelpersTests.swift
docs/manual-checks/m4.md
```

---

### Task 1: Engine — TCP segments with real checksums, generator datagrams, event and PDU views

**Files:**
- Modify: `Sources/PacEngine/PDU.swift`, `Sources/PacEngine/Runtime/EventViews.swift`, `Sources/PacEngine/Runtime/Protocol.swift` (only `Proto`), `Sources/PacEngine/L3/IpNode.swift` (only `deliver`), `Sources/PacTrack/Theme.swift` (exhaustive switch)
- Create: `Tests/PacEngineTests/TcpPduTests.swift`

**Interfaces:**
- Produces: `IPPROTO_TCP: UInt8 = 6`; `TRAFFIC_DATAGRAM = 1470`; `struct TcpFlags: OptionSet { fin, syn, rst, ack }` (wire bits 0x01/0x02/0x04/0x10); `struct TcpSegment { srcPort, dstPort: UInt16; seq, ack: UInt32; flags: TcpFlags; window: UInt16; checksum: UInt16 = 0; mss: UInt16? = nil; dataLength = 0; headerSize; size }`; `struct TrafficData { flow: Int; seq: Int; sentAt: Int }`; `UdpPayload.traffic(TrafficData)` (1470 B); `L4.tcp(TcpSegment)`; `serialize(_: TcpSegment) -> [UInt8]` (header only); `makeTcp(_:src:dst:) -> TcpSegment` (fills the checksum); `Proto.tcp`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/TcpPduTests.swift`:

```swift
import Testing
@testable import PacEngine

private let a: UInt32 = 0x0A00_0001
private let b: UInt32 = 0x0A00_0002

private func frame(_ l4: L4) -> EthernetFrame {
    EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV4,
                  payload: .ipv4(makeIpv4(src: a, dst: b, ttl: 64, id: 1, payload: l4)))
}

private let syn = makeTcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1000, ack: 0, flags: [.syn], window: 65535, mss: 1460), src: a, dst: b)
private let data = makeTcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1001, ack: 5001, flags: [.ack], window: 65535, dataLength: 1460),
                           src: a, dst: b)

@Suite struct TcpPduTests {
    @Test func sizesFollowTheHeaderAndTheMssOption() {
        #expect(syn.headerSize == 24 && syn.size == 24)
        #expect(data.headerSize == 20 && data.size == 1480)
        #expect(frame(.tcp(syn)).size == 58) // Ethernet 14 + IPv4 20 + TCP 20 + MSS option 4
        #expect(frame(.tcp(data)).size == 1514) // a full-sized segment fills the 1500-byte MTU
        let datagram = makeUdp(srcPort: 40000, dstPort: 9, payload: .traffic(TrafficData(flow: 1, seq: 7, sentAt: 0)))
        #expect(frame(.udp(datagram)).size == 1512) // iperf3's 1470-byte payload
        guard case .ipv4(let p) = frame(.tcp(syn)).payload else {
            Issue.record("not IPv4")
            return
        }
        #expect(p.proto == IPPROTO_TCP)
    }

    @Test func checksumsCoverThePseudoHeaderTheHeaderAndTheZeroPayload() {
        // Reference values computed independently (RFC 1071 sum over pseudo-header + header + zero data).
        #expect(syn.checksum == 0xE3F2)
        #expect(data.checksum == 0xE262)
        // A receiver's check: summing everything, checksum included, gives zero.
        let pseudo: [UInt8] = [10, 0, 0, 1, 10, 0, 0, 2, 0, 6, 0x05, 0xC8] // TCP length 1480
        #expect(internetChecksum(pseudo + serialize(data) + [UInt8](repeating: 0, count: 1460)) == 0)
    }

    @Test func describesSegmentsLikeWiresharkAndDecodesEveryHeaderField() {
        let e = SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(.tcp(syn)))
        let v = eventView(e)
        #expect(v.proto == .tcp && v.bytes == 58)
        #expect(v.info == "10.0.0.1 → 10.0.0.2 TCP 40000 → 9 [SYN] seq=1000 win=65535 len=0 mss=1460")
        #expect(eventView(SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(.tcp(data)))).info
            == "10.0.0.1 → 10.0.0.2 TCP 40000 → 9 [ACK] seq=1001 ack=5001 win=65535 len=1460")
        let rst = TcpSegment(srcPort: 9, dstPort: 40000, seq: 0, ack: 1001, flags: [.rst, .ack], window: 0)
        #expect(eventView(SimEvent(time: 0, kind: .tx, node: "B", iface: "eth0", frame: frame(.tcp(rst)))).info
            == "10.0.0.1 → 10.0.0.2 TCP 9 → 40000 [RST, ACK] seq=0 ack=1001 win=0 len=0")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv4", "TCP"])
        #expect(layers.map(\.bytes) == [58, 44, 24])
        #expect(layers[1].fields.first { $0.name == "Protocollo" }?.value == "6 (TCP)")
        #expect(layers[2].fields.map { "\($0.name): \($0.value)" } == [
            "Porta sorgente: 40000",
            "Porta destinazione: 9",
            "Numero di sequenza: 1000",
            "Numero di ack: 0",
            "Lungh. header: 24 B (data offset 6)",
            "Flag: 0x002 (SYN)",
            "Finestra: 65535",
            "Checksum: 0xe3f2",
            "Puntatore urgente: 0",
            "Opzione MSS: 1460 B",
            "Dati: 0 B",
        ])
    }

    @Test func generatorDatagramsAreUdpAndShowTheirSequenceNumber() {
        let u = makeUdp(srcPort: 40000, dstPort: 9, payload: .traffic(TrafficData(flow: 1, seq: 7, sentAt: 0)))
        let e = SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(.udp(u)))
        #expect(eventView(e).proto == .udp)
        #expect(eventView(e).info == "10.0.0.1 → 10.0.0.2 UDP 40000 → 9 ttl=64")
        #expect(pduLayers(e)[2].fields.last?.value == "1470 B (generatore di traffico, seq 7)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (outside the sandbox): `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `TcpSegment`, `makeTcp`, `TrafficData`, `L4.tcp` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/PDU.swift` — after `let IPPROTO_UDP: UInt8 = 17` add:

```swift
let IPPROTO_TCP: UInt8 = 6
```

After `let DNS_NXDOMAIN: UInt8 = 3` add:

```swift
/// iperf3's default UDP payload: with UDP, IPv4 and Ethernet headers the frame stays within a 1500-byte MTU.
let TRAFFIC_DATAGRAM = 1470
```

After `struct DnsMessage { … }` add:

```swift
/// A traffic generator datagram: like iperf3's payload it carries a sequence number and the send time (plus the flow id the sink reports to).
struct TrafficData: Equatable, Sendable {
    var flow: Int
    var seq: Int
    var sentAt: Int
}
```

In `enum UdpPayload` add the case and its size:

```swift
    case traffic(TrafficData)
```

```swift
        case .traffic: TRAFFIC_DATAGRAM
```

After `struct UdpDatagram { … }` add:

```swift
/// TCP flags Pac-Track uses, with their wire bits (PSH, URG, ECE, CWR are never set).
struct TcpFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let fin = TcpFlags(rawValue: 0x01)
    static let syn = TcpFlags(rawValue: 0x02)
    static let rst = TcpFlags(rawValue: 0x04)
    static let ack = TcpFlags(rawValue: 0x10)
}

/// TCP header with the MSS option on SYNs; the payload is `dataLength` zero bytes (only its size matters).
struct TcpSegment: Equatable, Sendable {
    var srcPort: UInt16
    var dstPort: UInt16
    var seq: UInt32
    var ack: UInt32
    var flags: TcpFlags
    var window: UInt16
    var checksum: UInt16 = 0
    var mss: UInt16? = nil
    var dataLength = 0

    var headerSize: Int { mss == nil ? 20 : 24 }
    var size: Int { headerSize + dataLength }
}
```

In `enum L4` add `case tcp(TcpSegment)` and in its `size` `case .tcp(let t): t.size`.

After `func serialize(_ u: UdpDatagram)` add:

```swift
/// Header with options; the zero payload is left out (it adds nothing to a checksum and is never quoted beyond 8 bytes).
func serialize(_ t: TcpSegment) -> [UInt8] {
    var b = u16(t.srcPort)
    b += u16(t.dstPort)
    b += u32(t.seq)
    b += u32(t.ack)
    b += [UInt8(t.headerSize / 4) << 4, t.flags.rawValue]
    b += u16(t.window)
    b += u16(t.checksum)
    b += u16(0) // urgent pointer
    if let mss = t.mss {
        b += [2, 4]
        b += u16(mss)
    }
    return b
}
```

In `serializeL4` add `case .tcp(let t): serialize(t)`. In `makeIpv4` add `case .tcp: IPPROTO_TCP` to the `proto` switch. After `makeUdp(srcPort:dstPort:payload:)` add:

```swift
/// Fills in the checksum over the pseudo-header (RFC 793 §3.1) and the header.
func makeTcp(_ t: TcpSegment, src: UInt32, dst: UInt32) -> TcpSegment {
    var s = t
    s.checksum = 0
    var pseudo = u32(src)
    pseudo += u32(dst)
    pseudo += [0, IPPROTO_TCP]
    pseudo += u16(UInt16(s.size))
    s.checksum = internetChecksum(pseudo + serialize(s))
    return s
}
```

`Sources/PacEngine/Runtime/Protocol.swift`:

```swift
public enum Proto: String, CaseIterable, Sendable {
    case arp, icmp, dhcp, dns, udp, tcp
}
```

`Sources/PacTrack/Theme.swift` — in `proto(_:)` add `case .tcp: Color(hex: 0x5FB865)`.

`Sources/PacEngine/L3/IpNode.swift` — in `deliver`, after the `.udp` case add:

```swift
        case .tcp:
            break // segments are ignored until the node has a TCP layer
```

`Sources/PacEngine/Runtime/EventViews.swift`:

Above `describe(_ p:)` add:

```swift
private let TCP_FLAG_NAMES: [(TcpFlags, String)] = [(.fin, "FIN"), (.syn, "SYN"), (.rst, "RST"), (.ack, "ACK")]

/// Wireshark order, lowest bit first: "SYN, ACK".
private func flagNames(_ f: TcpFlags) -> String {
    TCP_FLAG_NAMES.filter { f.contains($0.0) }.map { $0.1 }.joined(separator: ", ")
}
```

In `proto(of:)`: the inner UDP switch's last case becomes `case .raw, .traffic: .udp`, and the outer switch gains `case .tcp: .tcp`.

In `describe(_ p:)`: the inner UDP case `case .raw:` becomes `case .raw, .traffic:`, and the outer switch gains:

```swift
    case .tcp(let t):
        return "\(ends) TCP \(t.srcPort) → \(t.dstPort) [\(flagNames(t.flags))] seq=\(t.seq)" + (t.flags.contains(.ack) ? " ack=\(t.ack)" : "")
            + " win=\(t.window) len=\(t.dataLength)" + (t.mss.map { " mss=\($0)" } ?? "")
```

In `ipLayers`: the IPv4 "Protocollo" field becomes

```swift
        field("Protocollo", p.proto == IPPROTO_ICMP ? "1 (ICMP)" : p.proto == IPPROTO_TCP ? "6 (TCP)" : "17 (UDP)"),
```

the UDP `body` switch gains `case .traffic(let d): "\(TRAFFIC_DATAGRAM) B (generatore di traffico, seq \(d.seq))"`, its final switch's `case .raw:` becomes `case .raw, .traffic:`, and after the `.udp` case add:

```swift
    case .tcp(let t):
        var fields = [
            field("Porta sorgente", "\(t.srcPort)"),
            field("Porta destinazione", "\(t.dstPort)"),
            field("Numero di sequenza", "\(t.seq)"),
            field("Numero di ack", "\(t.ack)"),
            field("Lungh. header", "\(t.headerSize) B (data offset \(t.headerSize / 4))"),
            field("Flag", "\(hex(Int(t.flags.rawValue), digits: 3)) (\(flagNames(t.flags)))"),
            field("Finestra", "\(t.window)"),
            field("Checksum", hex(Int(t.checksum), digits: 4)),
            field("Puntatore urgente", "0"),
        ]
        if let mss = t.mss { fields.append(field("Opzione MSS", "\(mss) B")) }
        fields.append(field("Dati", "\(t.dataLength) B"))
        return [ip, PduLayer(title: "TCP", bytes: t.size, fields: fields)]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: `✔ Test run with … tests … passed` (4 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/PDU.swift Sources/PacEngine/Runtime/EventViews.swift Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/L3/IpNode.swift Sources/PacTrack/Theme.swift Tests/PacEngineTests/TcpPduTests.swift
git commit -m "feat(engine): add TCP segments with real checksums and generator datagrams, decode them in events and the PDU inspector

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Engine — TCP connections: handshake, sliding window, RFC 6298 retransmission, FIN/TIME_WAIT, RST

**Files:**
- Create: `Sources/PacEngine/L4/Tcp.swift`, `Tests/PacEngineTests/TcpTests.swift`
- Modify: `Sources/PacEngine/L3/IpNode.swift`

**Interfaces:**
- Consumes: Task 1 (`TcpSegment`, `TcpFlags`, `makeTcp`, `L4.tcp`), `Rng.uint32()`, `Rng.int(_:)`.
- Produces: `TCP_MSS = 1460`, `TCP_WINDOW = 65_535`, `TCP_MIN_RTO = 1 s`, `TCP_MAX_RTO = 120 s`, `TCP_MAX_RETRIES = 6`, `TCP_TIME_WAIT = 60 s`; `enum TcpState: String { synSent="SYN_SENT", synReceived="SYN_RECV", established="ESTABLISHED", finWait1="FIN_WAIT1", finWait2="FIN_WAIT2", lastAck="LAST_ACK", timeWait="TIME_WAIT", closed="CLOSED" }`; `enum TcpFailure: String { refused="Connection refused", timedOut="Connection timed out", reset="Connection reset by peer" }`; `final class Tcp { listening: [UInt16]; connections: [TcpConnection]; listen(_:) throws; unlisten(_:); connect(to:port:sending:) throws -> TcpConnection; input(_:_:); send(_:from:to:); remove(_:); reset() }`; `final class TcpConnection { localIp, localPort, remoteIp, remotePort, startedAt, state, failure, doneAt, onChange, segmentsSent, retransmissions, srtt, rto, bytesAcked; abort(); abandon() }`; `IpNode.tcp`; `IpNode.sendPacket(_:_:ttl:src:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/TcpTests.swift`:

```swift
import Testing
@testable import PacEngine

/// In-line two-port cable joint that drops the frames `lose` picks: deterministic loss.
private final class Tap: Node {
    var lose: (EthernetFrame) -> Bool = { _ in false }

    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("p0")
        addInterface("p1")
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        if lose(frame) { return sim.emit(.drop, node: id, iface: iface.name, frame: frame, reason: .loss) }
        interfaces.first { $0 !== iface }!.send(frame)
    }
}

/// H1 (10.0.0.1/24) — tap — H2 (10.0.0.2/24), both cables 1 Gb/s.
private func tapped() throws -> (sim: Sim, h1: Host, h2: Host, tap: Tap) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let tap = Tap(sim: sim, id: "T")
    _ = try Link(sim: sim, try h1.iface("eth0"), try tap.iface("p0"))
    _ = try Link(sim: sim, try tap.iface("p1"), try h2.iface("eth0"))
    try h1.setIp("eth0", "10.0.0.1/24")
    try h2.setIp("eth0", "10.0.0.2/24")
    return (sim, h1, h2, tap)
}

private func tcpOf(_ frame: EthernetFrame) -> TcpSegment? {
    guard case .ipv4(let p) = frame.payload, case .tcp(let t) = p.payload else { return nil }
    return t
}

/// TCP segments `node` started putting on the wire, in order.
private func segments(_ sim: Sim, _ node: String) -> [(time: Int, seg: TcpSegment)] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node, let t = e.frame.flatMap(tcpOf) else { return nil }
        return (e.time, t)
    }
}

/// tcpdump-style flags ("S", "S.", ".", "F.", "R.") plus the data length.
private func label(_ t: TcpSegment) -> String {
    let marks: [(TcpFlags, String)] = [(.syn, "S"), (.fin, "F"), (.rst, "R"), (.ack, ".")]
    return marks.filter { t.flags.contains($0.0) }.map { $0.1 }.joined() + (t.dataLength > 0 ? " \(t.dataLength)" : "")
}

@Suite struct TcpTests {
    @Test func connectsWithAThreeWayHandshakeSendsTheDataAndClosesWithFin() throws {
        let (sim, h1, h2, _) = try tapped()
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim.run(10 * MS)
        let a = segments(sim, "H1").map { $0.seg }
        let b = segments(sim, "H2").map { $0.seg }
        #expect(a.map(label) == ["S", ".", ". 1460", ". 1460", ". 80", "F.", "."])
        #expect(b.map(label) == ["S.", ".", ".", ".", "F."])
        let isn = a[0].seq
        let peer = b[0].seq
        #expect(a[0].mss == 1460 && b[0].mss == 1460 && a[1].mss == nil)
        #expect(a.allSatisfy { $0.window == 65535 } && b.allSatisfy { $0.window == 65535 })
        #expect(b[0].ack == isn &+ 1) // the SYN-ACK acknowledges the SYN…
        #expect(a[1].ack == peer &+ 1) // …and the ACK the SYN-ACK
        #expect(a[2...4].map { $0.seq &- isn } == [1, 1461, 2921]) // data numbered from ISN + 1
        #expect(b[1...3].map { $0.ack &- isn } == [1461, 2921, 3001]) // every segment acknowledged at once
        #expect(a[5].seq &- isn == 3001 && b[4].ack &- isn == 3002) // the FIN takes one sequence number
        #expect(a[6].ack == peer &+ 2)
        #expect(c.state == .timeWait && c.bytesAcked == 3000 && c.failure == nil)
        #expect(h2.tcp.connections.isEmpty) // LAST_ACK → CLOSED on the final ACK
        #expect(h1.tcp.connections.map(\.state) == [.timeWait])
        sim.run(60 * S)
        #expect(h1.tcp.connections.isEmpty && c.state == .closed)
        // The ISN comes from the seeded PRNG: same seed, same ISN.
        let (sim2, h1b, h2b, _) = try tapped()
        try h2b.tcp.listen(9)
        _ = try h1b.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim2.run(1 * MS)
        #expect(segments(sim2, "H1").first?.seg.seq == isn)
    }

    @Test func aClosedPortAnswersTheSynWithARst() throws {
        let (sim, h1, _, _) = try tapped()
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1000)
        sim.run(1 * MS)
        let syn = segments(sim, "H1")[0].seg
        let rst = segments(sim, "H2").map { $0.seg }
        #expect(rst.map(label) == ["R."])
        #expect(rst[0].seq == 0 && rst[0].ack == syn.seq &+ 1 && rst[0].window == 0)
        #expect(c.state == .closed && c.failure == .refused && h1.tcp.connections.isEmpty)
    }

    @Test func retransmitsALostSynAfter1SecondDoublingTheTimeoutAndGivesUpAfter127Seconds() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        tap.lose = { tcpOf($0) != nil } // ARP gets through, TCP does not
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1000)
        sim.run(126 * S)
        let syns = segments(sim, "H1")
        #expect(syns.map { label($0.seg) } == Array(repeating: "S", count: 7))
        #expect(syns.allSatisfy { $0.seg.seq == syns[0].seg.seq })
        #expect(syns.dropFirst().map { $0.time } == [1, 3, 7, 15, 31, 63].map { $0 * S }) // connect at 0; RTO 1, 2, 4 … 64 s
        #expect(c.state == .synSent)
        sim.run(2 * S)
        #expect(c.state == .closed && c.failure == .timedOut) // the 7th timeout, at 127 s
    }

    @Test func retransmitsALostLastSegmentWhenTheRetransmissionTimerExpires() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var dropped = false
        tap.lose = { f in
            guard !dropped, tcpOf(f)?.dataLength == 80 else { return false }
            dropped = true
            return true
        }
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim.run(2 * S)
        let tail = segments(sim, "H1").filter { $0.seg.dataLength == 80 }
        #expect(tail.count == 2)
        let gap = tail[1].time - tail[0].time
        #expect(gap >= 1 * S && gap < 1 * S + 1 * MS) // RTO: microsecond RTTs, but never below 1 s (RFC 6298 (2.4))
        #expect(c.retransmissions == 1 && c.state == .timeWait && c.bytesAcked == 3000)
        #expect(c.rto == 2 * S) // backed off; Karn: the retransmission gives no RTT sample to bring it back
    }

    @Test func aServerThatForgotTheConnectionResetsIt() throws {
        let (sim, h1, h2, _) = try tapped()
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 1_000_000)
        sim.run(1 * MS)
        #expect(h2.tcp.connections.map(\.state) == [.established])
        h2.reset() // a reboot: connections forgotten, the port still listening
        sim.run(1 * MS)
        #expect(segments(sim, "H2").map { label($0.seg) }.last == "R")
        #expect(c.state == .closed && c.failure == .reset)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `tcp`, `Tcp`, `TcpConnection`, `TcpState` unknown.

- [ ] **Step 3: Implement**

Create `Sources/PacEngine/L4/Tcp.swift`:

```swift
let TCP_MSS = 1460
/// RFC 879: the MSS to assume when a SYN carries no option.
private let TCP_DEFAULT_MSS = 536
/// Receive buffer and advertised window: 64 KB, no window scaling.
let TCP_WINDOW = 65_535
/// RFC 6298 (2.1), (2.4): 1 s before the first RTT sample and never less.
let TCP_MIN_RTO = 1 * S
/// RFC 6298 (2.5) allows any cap of at least 60 s; Linux TCP_RTO_MAX.
let TCP_MAX_RTO = 120 * S
/// Retransmissions of one segment before giving up (Linux tcp_syn_retries: the 7th SYN goes out at 63 s, failure at 127 s).
let TCP_MAX_RETRIES = 6
/// Linux TCP_TIMEWAIT_LEN.
let TCP_TIME_WAIT = 60 * S

/// RFC 793 states, named as netstat shows them. CLOSE_WAIT never lasts: the sink closes as soon as it reads the FIN.
enum TcpState: String, Sendable {
    case synSent = "SYN_SENT"
    case synReceived = "SYN_RECV"
    case established = "ESTABLISHED"
    case finWait1 = "FIN_WAIT1"
    case finWait2 = "FIN_WAIT2"
    case lastAck = "LAST_ACK"
    case timeWait = "TIME_WAIT"
    case closed = "CLOSED"
}

enum TcpFailure: String, Sendable {
    case refused = "Connection refused"
    case timedOut = "Connection timed out"
    case reset = "Connection reset by peer"
}

/// One end of a connection. The active end (the generator) sends `dataLength` bytes and closes; the passive end (the sink)
/// discards what arrives and closes when the peer does. Sequence numbers are offsets from each ISN: 0 is the SYN, data starts at 1.
// ponytail: one-way bulk data, no delayed ACK, SACK, timestamps, window scaling, persist or keepalive timers
final class TcpConnection {
    unowned let tcp: Tcp
    let localIp: UInt32
    let localPort: UInt16
    let remoteIp: UInt32
    let remotePort: UInt16
    let startedAt: Int
    private(set) var state: TcpState {
        didSet { if state != oldValue { onChange?() } }
    }
    private(set) var failure: TcpFailure?
    /// When the last data byte was acknowledged.
    private(set) var doneAt: Int?
    /// Called after every state change; the app reads the connection then.
    var onChange: (() -> Void)?
    /// Data segments put on the wire, retransmissions included.
    private(set) var segmentsSent = 0
    private(set) var retransmissions = 0

    // Send side.
    private let iss: UInt32
    private let dataLength: Int
    private var finQueued: Bool
    /// Oldest unacknowledged offset, next offset to send, highest offset ever sent.
    private var una = 0
    private var nxt = 0
    private var sentMax = 0
    private var mss = TCP_MSS
    private var peerWindow = TCP_WINDOW

    // RFC 6298 retransmission timer.
    private(set) var srtt: Int?
    private var rttvar = 0
    private(set) var rto = TCP_MIN_RTO
    /// The one segment being timed: its end offset and send time.
    private var timed: (end: Int, at: Int)?
    private var retries = 0
    private var synRetransmitted = false
    private var deadline: Int?
    private var armedAt: Int?
    private var timerGen = 0

    // Receive side.
    private var irs: UInt32 = 0
    private var rcvNxt = 0
    private var outOfOrder: [Range<Int>] = []
    /// Where the peer's FIN sits once seen (it may arrive before the data in front of it).
    private var peerFin: Int?

    init(tcp: Tcp, local: UInt32, localPort: UInt16, remote: UInt32, remotePort: UInt16, sending bytes: Int, state: TcpState) {
        self.tcp = tcp
        localIp = local
        self.localPort = localPort
        remoteIp = remote
        self.remotePort = remotePort
        startedAt = tcp.node.sim.now
        self.state = state
        dataLength = bytes
        // The generator closes as soon as its data is out; the sink when the peer does.
        finQueued = state == .synSent
        iss = tcp.node.sim.rng.uint32()
    }

    var bytesAcked: Int { min(max(una - 1, 0), dataLength) }

    private var now: Int { tcp.node.sim.now }
    /// Offset of the FIN: just past the data.
    private var dataEnd: Int { dataLength + 1 }

    /// Active open.
    func open() {
        output()
    }

    /// Passive open: answers a SYN that reached a listening port.
    func accept(_ syn: TcpSegment) {
        irs = syn.seq
        rcvNxt = 1
        learn(syn)
        output()
    }

    func receive(_ s: TcpSegment) {
        guard state != .closed else { return }
        // ponytail: any RST is believed (no RFC 5961 sequence check)
        if s.flags.contains(.rst) { return fail(state == .synSent ? .refused : .reset) }
        if state == .synSent {
            // ponytail: simultaneous open (a bare SYN while in SYN_SENT) is not modelled
            guard s.flags.contains([.syn, .ack]), ours(s.ack) == 1 else { return }
            irs = s.seq
            rcvNxt = 1
            learn(s)
            acknowledged(1, window: s.window)
            established()
            sendAck()
            return output()
        }
        // A repeated SYN-ACK (our ACK was lost) or a stray SYN: acknowledge it, nothing else.
        if s.flags.contains(.syn) { return sendAck() }
        guard s.flags.contains(.ack) else { return }
        let a = ours(s.ack)
        if a > una && a <= sentMax { acknowledged(a, window: s.window) }
        guard state != .closed else { return }
        if s.dataLength > 0 || s.flags.contains(.fin) { arrived(s) }
    }

    /// Kills the connection like SO_LINGER 0: one RST to the peer, then gone.
    func abort() {
        guard state != .closed else { return }
        if state != .synSent { send([.rst, .ack], at: nxt, length: 0) }
        close()
    }

    /// Power cycle: the connection vanishes without a word (its timers find it closed).
    func abandon() {
        deadline = nil
        state = .closed
    }

    private func learn(_ syn: TcpSegment) {
        mss = min(TCP_MSS, Int(syn.mss ?? UInt16(TCP_DEFAULT_MSS)))
        peerWindow = Int(syn.window)
    }

    /// Offset in our sequence space of an acknowledgment number.
    private func ours(_ ack: UInt32) -> Int {
        Int(ack &- iss)
    }

    /// A new cumulative ACK: everything before offset `a` arrived.
    private func acknowledged(_ a: Int, window: UInt16) {
        una = a
        nxt = max(nxt, una)
        peerWindow = Int(window)
        retries = 0
        if let t = timed, a >= t.end {
            measure(now - t.at)
            timed = nil
        }
        // RFC 6298 (5.2), (5.3): stop when everything is acknowledged, otherwise restart.
        setTimer(una == sentMax ? nil : now + rto)
        if doneAt == nil, dataLength > 0, una >= dataEnd { doneAt = now }
        switch state {
        case .synReceived: established()
        case .finWait1 where finQueued && una > dataEnd: state = .finWait2
        case .lastAck where una > dataEnd: close()
        default: break
        }
    }

    /// RFC 6298 (2.2), (2.3).
    private func measure(_ r: Int) {
        if let s = srtt {
            rttvar = (3 * rttvar + abs(s - r)) / 4
            srtt = (7 * s + r) / 8
        } else {
            srtt = r
            rttvar = r / 2
        }
        // ponytail: clock granularity G left out: the 1 s floor dwarfs it
        rto = min(max(srtt! + 4 * rttvar, TCP_MIN_RTO), TCP_MAX_RTO)
    }

    private func established() {
        // RFC 6298 (5.7): a SYN that timed out leaves at least a 3 s RTO.
        if synRetransmitted { rto = max(rto, 3 * S) }
        state = .established
    }

    /// Data or FIN from the peer: new bytes inside the window are kept (out-of-order pieces wait for the gap), then ACKed at once.
    private func arrived(_ s: TcpSegment) {
        let start = Int(s.seq &- irs)
        let end = start + s.dataLength
        if s.flags.contains(.fin) { peerFin = end }
        if s.dataLength > 0, end > rcvNxt, start < rcvNxt + TCP_WINDOW {
            outOfOrder.append(max(start, rcvNxt)..<end)
            outOfOrder.sort { $0.lowerBound < $1.lowerBound }
            while let first = outOfOrder.first, first.lowerBound <= rcvNxt {
                rcvNxt = max(rcvNxt, first.upperBound)
                outOfOrder.removeFirst()
            }
        }
        guard rcvNxt == peerFin else { return sendAck() }
        rcvNxt += 1
        switch state {
        case .established:
            // The sink reads end-of-file and closes at once: one FIN-ACK acknowledges the peer's FIN and carries ours.
            finQueued = true
            state = .lastAck
            output()
        case .finWait1, .finWait2:
            // ponytail: a FIN before ours is acknowledged (CLOSING) goes straight to TIME_WAIT
            sendAck()
            timeWait()
        default:
            sendAck()
        }
    }

    private func timeWait() {
        state = .timeWait
        setTimer(nil)
        // ponytail: a FIN repeated during TIME_WAIT is ACKed but does not restart the 60 s
        tcp.node.sim.sched.after(TCP_TIME_WAIT) { [self] in
            if state == .timeWait { close() }
        }
    }

    /// Sends what the window allows from `nxt`: the SYN, then full-sized segments (a short one only at the end), then the FIN.
    private func output() {
        if nxt == 0 {
            transmit(state == .synSent ? [.syn] : [.syn, .ack], at: 0, length: 0)
            nxt = 1
            return
        }
        guard state != .synSent && state != .synReceived else { return }
        let window = peerWindow
        while nxt < dataEnd {
            let length = min(mss, dataEnd - nxt)
            guard nxt + length - una <= window else { return }
            transmit([.ack], at: nxt, length: length)
            nxt += length
        }
        if finQueued && nxt == dataEnd {
            transmit([.fin, .ack], at: nxt, length: 0)
            nxt += 1
            if state == .established { state = .finWait1 }
        }
    }

    /// A segment that uses sequence space: RFC 6298 timing (Karn: never a retransmission) and timer start (5.1).
    private func transmit(_ flags: TcpFlags, at offset: Int, length: Int) {
        let span = length + (flags.contains(.syn) || flags.contains(.fin) ? 1 : 0)
        if offset < sentMax {
            timed = nil
            if length > 0 { retransmissions += 1 }
        } else if timed == nil {
            timed = (offset + span, now)
        }
        if length > 0 { segmentsSent += 1 }
        sentMax = max(sentMax, offset + span)
        send(flags, at: offset, length: length)
        if deadline == nil { setTimer(now + rto) }
    }

    private func sendAck() {
        send([.ack], at: nxt, length: 0)
    }

    private func send(_ flags: TcpFlags, at offset: Int, length: Int) {
        let s = TcpSegment(srcPort: localPort, dstPort: remotePort, seq: iss &+ UInt32(truncatingIfNeeded: offset),
                           ack: flags.contains(.ack) ? irs &+ UInt32(truncatingIfNeeded: rcvNxt) : 0, flags: flags,
                           window: UInt16(TCP_WINDOW), mss: flags.contains(.syn) ? UInt16(TCP_MSS) : nil, dataLength: length)
        tcp.send(s, from: localIp, to: remoteIp)
    }

    /// One pending scheduler callback at a time: a later deadline re-arms when it fires, an earlier one arms anew (generation check).
    private func setTimer(_ at: Int?) {
        deadline = at
        guard let at, armedAt.map({ at < $0 }) ?? true else { return }
        timerGen += 1
        let gen = timerGen
        armedAt = at
        tcp.node.sim.sched.at(at) { [self] in
            guard gen == timerGen else { return }
            armedAt = nil
            guard let due = deadline, state != .closed else { return }
            if now < due { return setTimer(due) }
            deadline = nil
            timeout()
        }
    }

    /// RFC 6298 (5.4)–(5.6): back off and go back to the oldest unacknowledged byte.
    private func timeout() {
        retries += 1
        guard retries <= TCP_MAX_RETRIES else { return fail(.timedOut) }
        if state == .synSent || state == .synReceived { synRetransmitted = true }
        rto = min(rto * 2, TCP_MAX_RTO)
        timed = nil
        nxt = una
        output()
    }

    private func fail(_ f: TcpFailure) {
        failure = f
        close()
    }

    private func close() {
        abandon()
        tcp.remove(self)
    }
}

/// A node's TCP: listening ports and open connections (both ordered, for deterministic display).
final class Tcp {
    unowned let node: IpNode
    private(set) var listening: [UInt16] = []
    private(set) var connections: [TcpConnection] = []

    init(node: IpNode) {
        self.node = node
    }

    func listen(_ port: UInt16) throws {
        guard !listening.contains(port) else { throw EngineError("TCP port \(port) already in use") }
        listening.append(port)
    }

    func unlisten(_ port: UInt16) {
        listening.removeAll { $0 == port }
    }

    /// Active open from a random ephemeral port (Linux range 32768–60999): sends `bytes`, then closes.
    func connect(to dst: UInt32, port: UInt16, sending bytes: Int) throws -> TcpConnection {
        guard let src = node.sourceFor(dst) else { throw EngineError("Network is unreachable") }
        for _ in 0..<16 {
            let local = UInt16(32768 + node.sim.rng.int(28232))
            guard !connections.contains(where: { $0.localPort == local }) else { continue }
            let c = TcpConnection(tcp: self, local: src, localPort: local, remote: dst, remotePort: port, sending: bytes, state: .synSent)
            connections.append(c)
            c.open()
            return c
        }
        throw EngineError("No free local port")
    }

    func input(_ p: Ipv4Packet, _ s: TcpSegment) {
        guard node.ownsIp(p.dst) else { return } // never to a broadcast address
        if let c = connections.first(where: {
            $0.localIp == p.dst && $0.localPort == s.dstPort && $0.remoteIp == p.src && $0.remotePort == s.srcPort
        }) {
            return c.receive(s)
        }
        if s.flags.contains(.rst) { return }
        if s.flags == [.syn], listening.contains(s.dstPort) {
            let c = TcpConnection(tcp: self, local: p.dst, localPort: s.dstPort, remote: p.src, remotePort: s.srcPort, sending: 0,
                                  state: .synReceived)
            connections.append(c)
            return c.accept(s)
        }
        refuse(p, s)
    }

    /// RFC 793 "Reset Generation": a segment for no connection gets a RST its sender will accept.
    private func refuse(_ p: Ipv4Packet, _ s: TcpSegment) {
        let rst: TcpSegment
        if s.flags.contains(.ack) {
            rst = TcpSegment(srcPort: s.dstPort, dstPort: s.srcPort, seq: s.ack, ack: 0, flags: [.rst], window: 0)
        } else {
            let length = UInt32(s.dataLength) + (s.flags.contains(.syn) ? 1 : 0) + (s.flags.contains(.fin) ? 1 : 0)
            rst = TcpSegment(srcPort: s.dstPort, dstPort: s.srcPort, seq: 0, ack: s.seq &+ length, flags: [.rst, .ack], window: 0)
        }
        send(rst, from: p.dst, to: p.src)
    }

    func send(_ s: TcpSegment, from src: UInt32, to dst: UInt32) {
        node.sendPacket(dst, .tcp(makeTcp(s, src: src, dst: dst)), src: src)
    }

    func remove(_ c: TcpConnection) {
        connections.removeAll { $0 === c }
    }

    /// Power cycle: connections vanish (the peer learns it from a RST later); listening ports are configuration and stay.
    func reset() {
        let all = connections
        connections = []
        for c in all { c.abandon() }
    }
}
```

`Sources/PacEngine/L3/IpNode.swift`:

After `private(set) lazy var resolver = Resolver(node: self)` add:

```swift
    private(set) lazy var tcp = Tcp(node: self)
```

`reset()` becomes:

```swift
    override func reset() {
        arp.reset()
        resolver.reset()
        dhcpServer?.reset()
        tcp.reset()
    }
```

`sendPacket` becomes (TCP answers from the address it was reached at, and its checksum covers that address):

```swift
    /// Originates a packet (from `src` if given, else the outgoing interface's address). Returns false when there is no route to `dst`.
    @discardableResult
    func sendPacket(_ dst: UInt32, _ payload: L4, ttl: UInt8? = nil, src: UInt32? = nil) -> Bool {
        guard let from = sourceFor(dst) else { return false }
        output(makeIpv4(src: src ?? from, dst: dst, ttl: ttl ?? defaultTtl, id: nextIpId(), payload: payload))
        return true
    }
```

In `deliver`, the `.tcp` case from Task 1 becomes:

```swift
        case .tcp(let t):
            tcp.input(p, t)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (5 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/L4/Tcp.swift Sources/PacEngine/L3/IpNode.swift Tests/PacEngineTests/TcpTests.swift
git commit -m "feat(engine): add TCP connections with handshake, sliding window, RFC 6298 retransmission, FIN/TIME_WAIT and RST

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Engine — Reno congestion control: slow start, congestion avoidance, fast retransmit

**Files:**
- Modify: `Sources/PacEngine/L4/Tcp.swift`
- Modify test: `Tests/PacEngineTests/TcpTests.swift`

**Interfaces:**
- Consumes: Task 2 (`TcpConnection`, the `tapped()`/`segments`/`tcpOf`/`label` test helpers).
- Produces: `TcpConnection.cwnd`, `TcpConnection.ssthresh` (`private(set)`, read by tests).

- [ ] **Step 1: Write the failing tests**

Append inside `struct TcpTests`:

```swift
    @Test func startsWithThreeSegmentsAndGrowsBySlowStartThenCongestionAvoidance() throws {
        let (sim, h1, h2, _) = try tapped()
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 100_000)
        var initial = 0
        c.onChange = { [unowned c] in if c.state == .established { initial = c.cwnd } }
        sim.run(100 * MS)
        #expect(initial == 4380) // RFC 5681 IW: min(4 × MSS, max(2 × MSS, 4380 B))
        #expect(c.bytesAcked == 100_000 && c.ssthresh == 65_535)
        // 69 ACKs, one per segment: the first 42 add 1 MSS each (slow start) and take cwnd past ssthresh;
        // the other 27 add ⌊MSS² / cwnd⌋ = 32 B each (congestion avoidance). The FIN's ACK adds nothing.
        #expect(c.cwnd == 66_564)
    }

    @Test func threeDuplicateAcksTriggerAFastRetransmitAndRenoHalvesTheWindow() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var seen = 0
        var lost: UInt32?
        tap.lose = { f in
            guard lost == nil, let t = tcpOf(f), t.dataLength > 0 else { return false }
            seen += 1
            guard seen == 5 else { return false }
            lost = t.seq
            return true
        }
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 100_000)
        sim.run(100 * MS)
        let copies = segments(sim, "H1").filter { $0.seg.seq == lost && $0.seg.dataLength > 0 }
        #expect(copies.count == 2)
        #expect(copies[1].time - copies[0].time < 1 * MS) // long before the 1 s RTO
        let acks = sim.log.all.filter { e in
            e.kind == .rx && e.node == "H1" && e.time <= copies[1].time && e.frame.flatMap(tcpOf).map { $0.ack == lost && $0.dataLength == 0 } == true
        }
        #expect(acks.count >= 4) // the ACK of the segment before, then at least three duplicates
        #expect(c.retransmissions == 1 && c.rto == 1 * S) // no timeout happened
        #expect(c.ssthresh < 65_535 && c.ssthresh >= 2 * TCP_MSS) // the window was halved
        #expect(c.state == .timeWait && c.bytesAcked == 100_000)
    }

    @Test func aTimeoutCollapsesTheWindowToOneSegment() throws {
        let (sim, h1, h2, tap) = try tapped()
        try h2.tcp.listen(9)
        var dropped = false
        tap.lose = { f in
            guard !dropped, tcpOf(f)?.dataLength == 80 else { return false }
            dropped = true
            return true
        }
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 3000)
        sim.run(2 * S)
        #expect(c.ssthresh == 2 * TCP_MSS) // max(FlightSize / 2 = 81 / 2 B, 2 × MSS)
        #expect(c.cwnd == TCP_MSS + 80) // one segment, then slow start on the 80 bytes acknowledged
        #expect(c.retransmissions == 1)
    }

    @Test func aBulkTransferFillsA10MbLinkToTheTheoreticalGoodput() throws {
        let sim = Sim()
        let h1 = Host(sim: sim, id: "H1")
        let h2 = Host(sim: sim, id: "H2")
        _ = try Link(sim: sim, try h1.iface("eth0"), try h2.iface("eth0"), LinkOptions(bandwidthBps: 10e6))
        try h1.setIp("eth0", "10.0.0.1/24")
        try h2.setIp("eth0", "10.0.0.2/24")
        try h2.tcp.listen(9)
        let c = try h1.tcp.connect(to: 0x0A00_0002, port: 9, sending: 2_000_000)
        sim.run(3 * S)
        let done = try #require(c.doneAt)
        let goodput = 2_000_000.0 * 8 / (Double(done - c.startedAt) / 1e9)
        // 1460 B of data per 1538 B on the wire (TCP 20 + IPv4 20 + Ethernet 14 + FCS 4 + preamble 8 + gap 12)
        let theory = 10e6 * 1460 / 1538
        #expect(abs(goodput - theory) / theory < 0.05)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `cwnd`, `ssthresh` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/L4/Tcp.swift`, in `TcpConnection`:

After the `// RFC 6298 retransmission timer.` block (after `private var timerGen = 0`) add:

```swift

    // RFC 5681 congestion control (Reno).
    private(set) var cwnd = TCP_MSS
    private(set) var ssthresh = TCP_WINDOW
    private var dupAcks = 0
    private var recovering = false
```

In `receive`, replace `if a > una && a <= sentMax { acknowledged(a, window: s.window) }` with:

```swift
        if a > una && a <= sentMax {
            acknowledged(a, window: s.window)
        } else if a == una && s.dataLength == 0 && !s.flags.contains(.fin) && sentMax > una && Int(s.window) == peerWindow {
            duplicateAck() // RFC 5681 §2: same ACK, no data, same window, data outstanding
        }
```

Replace `acknowledged(_:window:)`:

```swift
    /// A new cumulative ACK: everything before offset `a` arrived.
    private func acknowledged(_ a: Int, window: UInt16) {
        let newData = min(a, dataEnd) - min(una, dataEnd)
        una = a
        nxt = max(nxt, una)
        peerWindow = Int(window)
        retries = 0
        if let t = timed, a >= t.end {
            measure(now - t.at)
            timed = nil
        }
        if newData > 0 { grow(newData) }
        dupAcks = 0
        // RFC 6298 (5.2), (5.3): stop when everything is acknowledged, otherwise restart.
        setTimer(una == sentMax ? nil : now + rto)
        if doneAt == nil, dataLength > 0, una >= dataEnd { doneAt = now }
        switch state {
        case .synReceived: established()
        case .finWait1 where finQueued && una > dataEnd: state = .finWait2
        case .lastAck where una > dataEnd: close()
        default: break
        }
    }

    /// RFC 5681 §3.1: slow start below ssthresh, congestion avoidance above; §3.2 (6): Reno deflates on the first new ACK.
    private func grow(_ acked: Int) {
        if recovering {
            cwnd = ssthresh
            recovering = false
        } else if cwnd < ssthresh {
            cwnd += min(acked, mss)
        } else {
            cwnd += max(1, mss * mss / cwnd)
        }
    }

    /// RFC 5681 §3.2: the third duplicate retransmits the missing segment and enters fast recovery; later ones inflate the window.
    private func duplicateAck() {
        dupAcks += 1
        if dupAcks == 3 && !recovering && una < dataEnd {
            ssthresh = max((sentMax - una) / 2, 2 * mss)
            transmit([.ack], at: una, length: min(mss, dataEnd - una))
            cwnd = ssthresh + 3 * mss
            recovering = true
        } else if recovering {
            cwnd += mss
            output()
        }
    }
```

Replace `established()` (cwnd is set before the state so `onChange` sees it):

```swift
    private func established() {
        // RFC 6298 (5.7): a SYN that timed out leaves at least a 3 s RTO.
        if synRetransmitted { rto = max(rto, 3 * S) }
        // RFC 5681 §3.1: initial window min(4 × SMSS, max(2 × SMSS, 4380 B)); one segment if the SYN had to be repeated.
        cwnd = synRetransmitted ? mss : min(4 * mss, max(2 * mss, 4380))
        state = .established
    }
```

In `output()`, `let window = peerWindow` becomes:

```swift
        let window = min(cwnd, peerWindow)
```

Replace `timeout()`:

```swift
    /// RFC 6298 (5.4)–(5.6): back off and go back to the oldest unacknowledged byte; RFC 5681 (4): half the flight, one segment.
    private func timeout() {
        retries += 1
        guard retries <= TCP_MAX_RETRIES else { return fail(.timedOut) }
        if state == .synSent || state == .synReceived {
            synRetransmitted = true
        } else {
            ssthresh = max((sentMax - una) / 2, 2 * mss)
            cwnd = mss
        }
        dupAcks = 0
        recovering = false
        rto = min(rto * 2, TCP_MAX_RTO)
        timed = nil
        nxt = una
        output()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (4 more than before this task; Task 2's five TCP tests still pass unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/L4/Tcp.swift Tests/PacEngineTests/TcpTests.swift
git commit -m "feat(engine): add Reno congestion control with slow start, congestion avoidance and fast retransmit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Engine — discard sink and iperf3-style TCP and UDP flows with per-flow measurements

**Files:**
- Create: `Sources/PacEngine/Apps/Traffic.swift`, `Tests/PacEngineTests/TrafficTests.swift`
- Modify: `Sources/PacEngine/PDU.swift`, `Sources/PacEngine/Sim.swift`, `Sources/PacEngine/L3/IpNode.swift`, `Sources/PacEngine/Runtime/Protocol.swift` (only `FlowSample`)

**Interfaces:**
- Consumes: Tasks 1–3 (`TrafficData`, `.traffic`, `Tcp.listen/unlisten/connect`, `TcpConnection` fields, `abort()`), `literalIp`, `normalizeHostName`, `Resolver.resolve`, `formatMs`.
- Produces: `PORT_DISCARD: UInt16 = 9`; `Sim.flows: [Int: (TrafficData) -> Void]`; `IpNode.sink: Bool`, `IpNode.configureSink(_:) throws`; `SAMPLE_NS = 100 ms`, `METRICS_HISTORY = 600`; `struct TrafficResult { lines; done; samples: [FlowSample] }`; `final class TcpFlow { init(node:target:bytes:) throws; result; stop(); sample(at:) }`; `final class UdpFlow { init(node:target:bitsPerSecond:seconds:) throws; result; stop(); sample(at:) }`; `public struct FlowSample { timeNs, bitsPerSecond, delayNs?, jitterNs?, lossPct }` with public init.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/TrafficTests.swift`:

```swift
import Testing
@testable import PacEngine

/// H1 (10.0.0.1/24) cabled straight to SRV (10.0.0.2/24) at 10 Mb/s.
private func direct(sink: Bool = true) throws -> (sim: Sim, h1: Host, srv: Host) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let srv = Host(sim: sim, id: "SRV")
    _ = try Link(sim: sim, try h1.iface("eth0"), try srv.iface("eth0"), LinkOptions(bandwidthBps: 10e6))
    try h1.setIp("eth0", "10.0.0.1/24")
    try srv.setIp("eth0", "10.0.0.2/24")
    try srv.configureSink(sink)
    return (sim, h1, srv)
}

/// Runs to `seconds`, calling `sample` at every 100 ms boundary as the runtime does.
private func run(_ sim: Sim, seconds: Int, _ sample: (Int) -> Void) {
    var t = SAMPLE_NS
    while t <= seconds * S {
        sim.sched.runUntil(t)
        sample(t)
        t += SAMPLE_NS
    }
}

/// 10 Mb/s × 1460 / 1538: data bytes per wire byte of a full-sized segment.
private let GOODPUT_10MB = 9_492_848.0

@Suite struct TrafficTests {
    @Test func theSinkListensOnTcpAndUdpPort9UntilTurnedOff() throws {
        let (_, _, srv) = try direct()
        #expect(srv.sink && srv.tcp.listening == [9])
        expectError("UDP port 9 already in use") { try srv.bindUdp(9) { _, _, _ in } }
        try srv.configureSink(false)
        #expect(!srv.sink && srv.tcp.listening.isEmpty)
        try srv.bindUdp(9) { _, _, _ in }
    }

    @Test func tcpFlowSendsItsBytesToTheSinkAndReportsLikeIperf3() throws {
        let (sim, h1, srv) = try direct()
        let flow = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 1_000_000)
        run(sim, seconds: 2) { flow.sample(at: $0) }
        let lines = flow.result.lines
        #expect(lines.count == 4 && flow.result.done)
        #expect(lines[0] == "Connecting to host 10.0.0.2, port 9")
        #expect(lines[1].hasPrefix("[  1] local 10.0.0.1 port ") && lines[1].hasSuffix(" connected to 10.0.0.2 port 9"))
        // ≈ 0.843 s for 685 segments on the wire at 10 Mb/s
        #expect(lines[2].hasPrefix("[  1]   0.00-0.84 sec  1000000 bytes  9.4") && lines[2].hasSuffix(" Mbits/sec  0 retr"))
        #expect(lines[3] == "iperf Done.")
        let samples = flow.result.samples
        #expect(samples.count == 8) // 100 … 800 ms: TIME_WAIT (the end of the flow) comes before 900 ms
        for s in samples[1...6] { #expect(abs(s.bitsPerSecond - GOODPUT_10MB) / GOODPUT_10MB < 0.05) }
        #expect(samples.allSatisfy { $0.jitterNs == nil && $0.lossPct == 0 && $0.delayNs != nil })
        #expect(srv.tcp.connections.isEmpty)
    }

    @Test func tcpFlowToAHostWithoutTheSinkIsRefused() throws {
        let (sim, h1, _) = try direct(sink: false)
        let flow = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 1000)
        sim.run(10 * MS)
        #expect(flow.result.lines == ["Connecting to host 10.0.0.2, port 9", "iperf3: error - unable to connect to server: Connection refused"])
        #expect(flow.result.done && flow.result.samples.isEmpty)
    }

    @Test func stoppingATcpFlowResetsTheConnection() throws {
        let (sim, h1, srv) = try direct()
        let flow = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 100_000_000)
        sim.run(50 * MS)
        #expect(srv.tcp.connections.map(\.state) == [.established])
        flow.stop()
        sim.run(200 * MS) // the RST waits behind the data already queued on the cable
        #expect(flow.result.lines.last == "iperf3: interrupt - the client has terminated" && flow.result.done)
        #expect(srv.tcp.connections.isEmpty && h1.tcp.connections.isEmpty)
    }

    @Test func udpFlowSendsAConstantBitrateAndMeasuresWhatTheSinkReceived() throws {
        let (sim, h1, _) = try direct()
        let flow = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 1)
        run(sim, seconds: 3) { flow.sample(at: $0) }
        let lines = flow.result.lines
        #expect(lines.count == 4 && flow.result.done)
        #expect(lines[1].hasPrefix("[  1] local 10.0.0.1 port "))
        // 86 datagrams of 1470 B, one every 11.76 ms; only the first waited for ARP (135.4 µs), so the jitter decays to ~37 ns
        #expect(lines[2] == "[  1]   0.00-1.00 sec  126420 bytes  1.01 Mbits/sec  0.000 ms  0/86 (0%)")
        #expect(lines[3] == "iperf Done.")
        let samples = flow.result.samples
        #expect(samples.count == 19) // 100 … 1900 ms: the report at 2 s ends the flow
        #expect(samples[1].delayNs == 1_229_300) // 1536 wire bytes at 10 Mb/s + 500 ns of cable
        #expect(samples.allSatisfy { $0.lossPct == 0 && $0.jitterNs != nil })
        #expect(samples[11...].allSatisfy { $0.bitsPerSecond == 0 }) // nothing arrives after 1.1 s
    }

    @Test func udpFlowToAHostWithoutTheSinkLosesEverything() throws {
        let (sim, h1, _) = try direct(sink: false)
        let flow = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 1)
        sim.run(3 * S)
        #expect(flow.result.lines[2] == "[  1]   0.00-1.00 sec  0 bytes  0.00 Mbits/sec  0.000 ms  86/86 (100%)")
        #expect(sim.log.all.contains { $0.kind == .tx && $0.node == "SRV" && eventView($0).info.contains("Destination unreachable (port)") })
    }

    @Test func rejectsOutOfRangeSettingsBeforeSendingAnything() throws {
        let (sim, h1, _) = try direct()
        expectError("Bytes must be between 1 and 1000000000") { _ = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 0) }
        expectError("Bitrate must be between 1 kb/s and 1 Gb/s") { _ = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 999, seconds: 1) }
        expectError("Duration must be between 1 and 3600 s") { _ = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 3601) }
        expectError("Invalid address or host name") { _ = try UdpFlow(node: h1, target: "a b", bitsPerSecond: 1e6, seconds: 1) }
        #expect(sim.log.all.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `configureSink`, `TcpFlow`, `UdpFlow`, `SAMPLE_NS` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/PDU.swift` — after `let PORT_DNS: UInt16 = 53` add:

```swift
/// Discard service (RFC 863): the traffic generator's receiver, TCP and UDP.
let PORT_DISCARD: UInt16 = 9
```

`Sources/PacEngine/Sim.swift` — after `let log: EventLog` add:

```swift
    /// Traffic generator flows by id: the sink that receives one of a flow's datagrams hands it back here.
    var flows: [Int: (TrafficData) -> Void] = [:]
```

`Sources/PacEngine/L3/IpNode.swift` — after `var dnsServer: DnsServer?` add:

```swift
    /// Turns the discard sink off again; nil while it is off.
    private var sinkStop: (() -> Void)?

    /// Discard service on TCP and UDP port 9: accepts connections and datagrams and drops the data.
    var sink: Bool { sinkStop != nil }
```

and after `onIcmp(_:)` add:

```swift
    func configureSink(_ on: Bool) throws {
        guard on != sink else { return }
        guard on else {
            sinkStop?()
            sinkStop = nil
            return
        }
        try tcp.listen(PORT_DISCARD)
        let unbind: () -> Void
        do {
            unbind = try bindUdp(PORT_DISCARD) { [unowned self] _, u, _ in
                if case .traffic(let d) = u.payload { self.sim.flows[d.flow]?(d) }
            }
        } catch {
            tcp.unlisten(PORT_DISCARD)
            throw error
        }
        sinkStop = { [unowned self] in
            unbind()
            self.tcp.unlisten(PORT_DISCARD)
        }
    }
```

`Sources/PacEngine/Runtime/Protocol.swift` — after `struct DhcpClientView { … }` add:

```swift
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
```

Create `Sources/PacEngine/Apps/Traffic.swift`:

```swift
import Foundation

/// Metrics interval (spec §5.6).
let SAMPLE_NS = 100 * MS
/// Points kept per flow and per cable: the last minute.
let METRICS_HISTORY = 600
/// UDP: like iperf3 waiting for the server's report, the summary comes this long after the last datagram.
private let UDP_REPORT_DELAY = 1 * S

struct TrafficResult: Sendable {
    var lines: [String] = []
    var done = false
    var samples: [FlowSample] = []
}

private func twoDecimals(_ v: Double) -> String {
    String(format: "%.2f", v)
}

private func keep(_ s: FlowSample, in samples: inout [FlowSample]) {
    samples.append(s)
    if samples.count > METRICS_HISTORY { samples.removeFirst() }
}

private func bitsPerSecond(_ bytes: Int) -> Double {
    Double(bytes) * 8 * Double(S) / Double(SAMPLE_NS)
}

private func resolutionError(_ target: String, _ r: Resolution) -> String {
    "iperf3: error - unable to resolve host \(target): " + (r == .nxdomain ? "Name or service not known" : "Temporary failure in name resolution")
}

/// iperf3-style TCP client: connects to the discard port, sends `bytes`, closes, and reports goodput and retransmissions.
/// The connection's timers keep it alive; it learns of every state change through `onChange` (captured weak).
final class TcpFlow {
    private(set) var result = TrafficResult()
    private let node: IpNode
    private let target: String
    private let bytes: Int
    private var conn: TcpConnection?
    private var connected = false
    private var lastAcked = 0

    init(node: IpNode, target: String, bytes: Int) throws {
        guard (1...1_000_000_000).contains(bytes) else { throw EngineError("Bytes must be between 1 and 1000000000") }
        self.node = node
        self.target = target
        self.bytes = bytes
        let literal = try literalIp(target)
        let name = literal == nil ? normalizeHostName(target) : nil
        guard literal != nil || name != nil else { throw EngineError("Invalid address or host name: \"\(target)\"") }
        if let literal {
            begin(literal)
            return
        }
        node.resolver.resolve(name!) { [weak self] r in self?.resolved(r) }
    }

    func stop() {
        guard !result.done else { return }
        conn?.abort()
        if !result.done {
            result.lines.append("iperf3: interrupt - the client has terminated")
            result.done = true
        }
    }

    func sample(at time: Int) {
        guard !result.done, let c = conn else { return }
        let acked = c.bytesAcked
        let loss = c.segmentsSent == 0 ? 0 : Double(c.retransmissions) / Double(c.segmentsSent) * 100
        keep(FlowSample(timeNs: time, bitsPerSecond: bitsPerSecond(acked - lastAcked), delayNs: c.srtt, jitterNs: nil, lossPct: loss),
             in: &result.samples)
        lastAcked = acked
    }

    private func resolved(_ r: Resolution) {
        guard !result.done else { return }
        if case .found(let addrs) = r, let first = addrs.first { return begin(first) }
        result.lines = [resolutionError(target, r)]
        result.done = true
    }

    private func begin(_ ip: UInt32) {
        result.lines = ["Connecting to host \(formatIp(ip)), port \(PORT_DISCARD)"]
        do {
            let c = try node.tcp.connect(to: ip, port: PORT_DISCARD, sending: bytes)
            c.onChange = { [weak self] in self?.update() }
            conn = c
        } catch {
            result.lines.append("iperf3: error - unable to connect to server: \(error)")
            result.done = true
        }
    }

    private func update() {
        guard let c = conn, !result.done else { return }
        if c.state == .established && !connected {
            connected = true
            result.lines.append("[  1] local \(formatIp(c.localIp)) port \(c.localPort) connected to \(formatIp(c.remoteIp)) port \(c.remotePort)")
        }
        guard c.state == .timeWait || c.state == .closed else { return }
        if let f = c.failure {
            result.lines.append(connected ? "iperf3: error - \(f.rawValue)" : "iperf3: error - unable to connect to server: \(f.rawValue)")
        } else if let done = c.doneAt {
            let seconds = Double(done - c.startedAt) / Double(S)
            result.lines.append("[  1]   0.00-\(twoDecimals(seconds)) sec  \(bytes) bytes  \(twoDecimals(Double(bytes) * 8 / seconds / 1e6)) Mbits/sec  \(c.retransmissions) retr")
            result.lines.append("iperf Done.")
        } else {
            result.lines.append("iperf3: interrupt - the client has terminated")
        }
        result.done = true
    }
}

/// iperf3-style UDP client: `bitsPerSecond` of 1470-byte datagrams to the discard port for `seconds`, evenly paced. The sink hands
/// every datagram back by flow id, so the flow measures what the receiver saw: one-way delay, RFC 3550 jitter and loss.
/// Pending timers keep it alive; it stores none (a retain cycle), so callbacks check `result.done`.
final class UdpFlow {
    private(set) var result = TrafficResult()
    private let node: IpNode
    private let target: String
    private let seconds: Int
    private let interval: Int
    private let count: Int
    private let flow: Int
    private let srcPort: UInt16
    private var dst: UInt32 = 0
    private var startedAt = 0
    private var sent = 0
    private var received = 0
    private var highest = -1
    private var transit: Int?
    private var jitter = 0.0
    private var lastBytes = 0
    private var delaySum = 0
    private var delayCount = 0

    init(node: IpNode, target: String, bitsPerSecond: Double, seconds: Int) throws {
        guard bitsPerSecond >= 1_000 && bitsPerSecond <= 1e9 else { throw EngineError("Bitrate must be between 1 kb/s and 1 Gb/s") }
        guard (1...3600).contains(seconds) else { throw EngineError("Duration must be between 1 and 3600 s") }
        self.node = node
        self.target = target
        self.seconds = seconds
        interval = Int((Double(TRAFFIC_DATAGRAM * 8) * Double(S) / bitsPerSecond).rounded())
        count = (seconds * S + interval - 1) / interval
        let literal = try literalIp(target)
        let name = literal == nil ? normalizeHostName(target) : nil
        guard literal != nil || name != nil else { throw EngineError("Invalid address or host name: \"\(target)\"") }
        flow = node.sim.nextId()
        srcPort = UInt16(32768 + node.sim.rng.int(28232))
        if let literal {
            begin(literal)
            return
        }
        node.resolver.resolve(name!) { [weak self] r in self?.resolved(r) }
    }

    func stop() {
        guard !result.done else { return }
        guard sent > 0 else {
            result.lines.append("iperf3: interrupt - the client has terminated")
            return finish()
        }
        report()
    }

    func sample(at time: Int) {
        guard !result.done, sent > 0 else { return }
        let bytes = received * TRAFFIC_DATAGRAM
        let loss = highest < 0 ? 0 : Double(highest + 1 - received) / Double(highest + 1) * 100
        keep(FlowSample(timeNs: time, bitsPerSecond: bitsPerSecond(bytes - lastBytes), delayNs: delayCount == 0 ? nil : delaySum / delayCount,
                        jitterNs: Int(jitter.rounded()), lossPct: loss), in: &result.samples)
        lastBytes = bytes
        delaySum = 0
        delayCount = 0
    }

    private func resolved(_ r: Resolution) {
        guard !result.done else { return }
        if case .found(let addrs) = r, let first = addrs.first { return begin(first) }
        result.lines = [resolutionError(target, r)]
        result.done = true
    }

    private func begin(_ ip: UInt32) {
        dst = ip
        startedAt = node.sim.now
        result.lines = ["Connecting to host \(formatIp(ip)), port \(PORT_DISCARD)"]
        guard let src = node.sourceFor(ip) else {
            result.lines.append("iperf3: error - unable to connect to server: Network is unreachable")
            return finish()
        }
        result.lines.append("[  1] local \(formatIp(src)) port \(srcPort) connected to \(formatIp(ip)) port \(PORT_DISCARD)")
        node.sim.flows[flow] = { [weak self] d in self?.arrived(d) }
        send(0)
        node.sim.sched.after(seconds * S + UDP_REPORT_DELAY) { [self] in report() }
    }

    private func send(_ seq: Int) {
        guard !result.done else { return }
        node.sendUdp(dst, srcPort: srcPort, dstPort: PORT_DISCARD, payload: .traffic(TrafficData(flow: flow, seq: seq, sentAt: node.sim.now)))
        sent += 1
        if seq + 1 < count { node.sim.sched.after(interval) { [self] in send(seq + 1) } }
    }

    private func arrived(_ d: TrafficData) {
        guard !result.done else { return }
        let t = node.sim.now - d.sentAt
        if let previous = transit { jitter += (Double(abs(t - previous)) - jitter) / 16 } // RFC 3550 §6.4.1
        transit = t
        received += 1
        highest = max(highest, d.seq)
        delaySum += t
        delayCount += 1
    }

    /// iperf3's closing line: what the receiver got over the configured time (or until stopped).
    private func report() {
        guard !result.done else { return }
        let elapsed = Double(min(node.sim.now - startedAt, seconds * S)) / Double(S)
        let bytes = received * TRAFFIC_DATAGRAM
        let lost = sent - received
        let pct = Int((Double(lost) / Double(sent) * 100).rounded())
        let rate = elapsed == 0 ? 0 : Double(bytes) * 8 / elapsed / 1e6
        result.lines.append("[  1]   0.00-\(twoDecimals(elapsed)) sec  \(bytes) bytes  \(twoDecimals(rate)) Mbits/sec  "
            + "\(formatMs(Int(jitter.rounded()))) ms  \(lost)/\(sent) (\(pct)%)")
        result.lines.append("iperf Done.")
        finish()
    }

    private func finish() {
        result.done = true
        node.sim.flows[flow] = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (7 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/PDU.swift Sources/PacEngine/Sim.swift Sources/PacEngine/L3/IpNode.swift Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Apps/Traffic.swift Tests/PacEngineTests/TrafficTests.swift
git commit -m "feat(engine): add the discard sink and iperf3-style TCP and UDP flows with per-flow measurements

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Runtime — traffic commands, sink, TCP table, cables and flows sampled every 100 ms, persistence

**Files:**
- Modify: `Sources/PacEngine/Runtime/Protocol.swift`, `Sources/PacEngine/Runtime/Runtime.swift`, `Sources/PacEngine/Link.swift`, `Sources/PacEngine/Scheduler.swift`
- Create: `Tests/PacEngineTests/RuntimeTrafficTests.swift`

**Interfaces:**
- Consumes: Task 2 (`Tcp.listening/connections`, `TcpConnection` address fields and `state`), Task 4 (`configureSink`, `sink`, `TcpFlow`, `UdpFlow`, `FlowSample`, `SAMPLE_NS`, `METRICS_HISTORY`).
- Produces (public): `Command.setSink(node:on:)`, `.trafficTcp(node:target:bytes:)`, `.trafficUdp(node:target:bitsPerSecond:seconds:)` (keys = case names); `struct TcpRow { local, remote, state: String }`; `struct DirectionSample { utilization: Double; queued: Int; drops: Int }` and `struct LinkSample { timeNs; ab; ba: DirectionSample }`, both with public init; `NodeView.sink`, `NodeView.tcp: [TcpRow]`; `AppView.samples: [FlowSample]`; `Snapshot.linkSamples: [String: [LinkSample]]`; `TopologyNode.sink` (init default `false`). Internal: `LinkCounters`, `Link.counters()`, `Scheduler.runUntil` returns the events run, `Scheduler.nextTime`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/RuntimeTrafficTests.swift`:

```swift
import Foundation
import Testing
@testable import PacEngine

/// SW1 with SRV1 (10.0.0.2/24, sink on, behind the 10 Mb/s cable l1) and PC1 (10.0.0.1/24, cable l2).
private func trafficRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "s", kind: .switch, name: "SW1"))
    try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "s", iface: "Gi0/1"), b: IfaceRef(node: "srv", iface: "eth0")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "s", iface: "Gi0/2")))
    try rt.handle(.updateLink(id: "l1", options: LinkOptions(bandwidthBps: 10e6)))
    try rt.handle(.setIp(node: "srv", iface: "eth0", cidr: "10.0.0.2/24"))
    try rt.handle(.setIp(node: "a", iface: "eth0", cidr: "10.0.0.1/24"))
    try rt.handle(.setSink(node: "srv", on: true))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

private let GOODPUT_10MB = 9_492_848.0

@Suite struct RuntimeTrafficTests {
    @Test func runsTcpTrafficAndSamplesTheFlowAndEveryCableEvery100ms() throws {
        let rt = try trafficRuntime()
        try rt.handle(.trafficTcp(node: "a", target: " 10.0.0.2 ", bytes: 1_000_000))
        runFor(rt, wallMs: 2_000)
        let s = rt.snapshot()
        let app = s.apps[0]
        #expect(app.title == "iperf3 -c 10.0.0.2 -p 9 -n 1000000" && app.done && app.lines.last == "iperf Done.")
        let cable = try #require(s.linkSamples["l1"])
        #expect(cable.count == 20 && cable.first?.timeNs == 100 * MS && cable.last?.timeNs == 2 * S)
        #expect(cable[3].ab.utilization > 0.95) // SW1 → SRV1 is the 10 Mb/s bottleneck
        #expect(cable[3].ba.utilization < 0.1) // only ACKs come back (84 of every 1538 wire bytes)
        #expect(s.linkSamples["l2"]?.count == 20)
        #expect(abs(app.samples[3].bitsPerSecond - GOODPUT_10MB) / GOODPUT_10MB < 0.05)
        #expect(app.samples.allSatisfy { $0.jitterNs == nil && $0.lossPct == 0 } && app.samples[3].delayNs != nil)
        #expect(s.nodes[1].sink && s.nodes[1].tcp == [TcpRow(local: "0.0.0.0:9", remote: "0.0.0.0:*", state: "LISTEN")])
        #expect(s.nodes[2].tcp.map { "\($0.remote) \($0.state)" } == ["10.0.0.2:9 TIME_WAIT"])
        try rt.handle(.disconnect(id: "l2"))
        #expect(rt.snapshot().linkSamples["l2"] == nil)
        try rt.handle(.load(Topology(seed: 1)))
        #expect(rt.snapshot().linkSamples.isEmpty)
    }

    @Test func udpAboveTheCableRateFillsTheQueueAndTailDrops() throws {
        let rt = try trafficRuntime()
        try rt.handle(.updateLink(id: "l1", options: LinkOptions(bandwidthBps: 10e6, queueLimit: 10)))
        try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: 20e6, seconds: 1))
        runFor(rt, wallMs: 3_000)
        let s = rt.snapshot()
        let app = s.apps[0]
        #expect(app.title == "iperf3 -u -c 10.0.0.2 -p 9 -b 20000000 -t 1" && app.done)
        #expect(app.lines[2].contains("/1701 (") && !app.lines[2].hasSuffix("(0%)")) // 1701 datagrams, one every 588 µs
        let cable = try #require(s.linkSamples["l1"])
        #expect(cable.map(\.ab.queued).max() == 10) // the queue fills to its limit…
        #expect(cable.reduce(0) { $0 + $1.ab.drops } > 700) // …and drops about half the datagrams
        #expect(app.samples.last!.lossPct > 40 && app.samples.allSatisfy { $0.jitterNs != nil })
    }

    @Test func rejectsBadTrafficSettingsAndSinksOnHosts() throws {
        let rt = try trafficRuntime()
        expectError("Bytes must be between 1 and 1000000000") { try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 0)) }
        expectError("Bitrate must be between 1 kb/s and 1 Gb/s") {
            try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: .nan, seconds: 1))
        }
        expectError("Bitrate must be between") { try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: 2e9, seconds: 1)) }
        expectError("Duration must be between 1 and 3600 s") {
            try rt.handle(.trafficUdp(node: "a", target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 0))
        }
        expectError("Invalid address or host name") { try rt.handle(.trafficTcp(node: "a", target: "a b", bytes: 10)) }
        expectError("PC1 cannot run a traffic sink") { try rt.handle(.setSink(node: "a", on: true)) }
        expectError("SW1 has no IP stack") { try rt.handle(.trafficTcp(node: "s", target: "10.0.0.2", bytes: 10)) }
        try rt.handle(.setPower(id: "a", on: false))
        expectError("PC1 is powered off") { try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 10)) }
        #expect(rt.snapshot().apps.isEmpty)
    }

    @Test func poweringTheSenderOffEndsItsFlow() throws {
        let rt = try trafficRuntime()
        try rt.handle(.trafficTcp(node: "a", target: "10.0.0.2", bytes: 100_000_000))
        runFor(rt, wallMs: 300)
        try rt.handle(.setPower(id: "a", on: false))
        let s = rt.snapshot()
        #expect(s.apps[0].done && s.apps[0].lines.last == "iperf3: interrupt - the client has terminated")
        #expect(s.nodes[2].tcp.isEmpty)
    }

    @Test func steppingOverAnIdleHalfDayKeepsOnlyTheLastMinuteOfSamples() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
        try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "srv", iface: "eth0")))
        try rt.handle(.setIp(node: "srv", iface: "eth0", cidr: "10.0.0.2/24"))
        try rt.handle(.setDhcpServer(node: "srv", config: DhcpConfig(start: "10.0.0.100", end: "10.0.0.199")))
        try rt.handle(.setMode(.simulation))
        try rt.handle(.setIfaceMode(node: "a", iface: "eth0", mode: .dhcp))
        // DORA takes a handful of steps; then the next logged event is the renewal at T1 = 43 200 s.
        for _ in 0..<100 where rt.snapshot().timeNs < 3600 * S { try rt.handle(.step) }
        let s = rt.snapshot()
        #expect(s.timeNs >= 43_200 * S)
        let series = try #require(s.linkSamples["l"])
        #expect(series.count == 600)
        #expect(zip(series, series.dropFirst()).allSatisfy { $1.timeNs - $0.timeNs == 100 * MS })
        #expect(series.last!.timeNs == (s.timeNs - 1) / (100 * MS) * (100 * MS)) // the last boundary before the event
    }

    @Test func loadsTheSinkAndOpensOlderFilesWithItOff() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "srv", kind: .server, name: "SRV1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "eth0", cidr: "10.0.0.2/24")],
                         routes: [], sink: true),
        ])
        let rt = Runtime()
        try rt.handle(.load(t))
        #expect(rt.snapshot().nodes[0].sink && rt.snapshot().nodes[0].tcp.map(\.state) == ["LISTEN"])
        let old = #"{"id":"srv","kind":"server","name":"SRV1","pos":{"x":0,"y":0},"ifaces":[],"routes":[]}"#
        #expect(try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8)).sink == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `.setSink`, `.trafficTcp`, `linkSamples`, `TcpRow`, `TopologyNode(…sink:)` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Scheduler.swift` — replace `runUntil` and add `nextTime`:

```swift
    /// Runs events up to `time`. With a budget, stops after `maxEvents` and leaves `now` at the last event run. Returns the events run.
    @discardableResult
    func runUntil(_ time: Int, maxEvents: Int = .max) -> Int {
        var count = 0
        while count < maxEvents, let timer = peek(), timer.time <= time {
            step()
            count += 1
        }
        if count < maxEvents, time > now { now = time }
        return count
    }

    /// Time of the next live event, if any.
    var nextTime: Int? { peek()?.time }
```

`Sources/PacEngine/Link.swift`:

Before `private final class Direction` add:

```swift
/// Totals for one direction of a cable since it was plugged; the runtime turns them into 100 ms points.
struct LinkCounters {
    var busyNs = 0
    var drops = 0
    var queued = 0
}
```

`Direction` becomes:

```swift
private final class Direction {
    var queue: [EthernetFrame] = []
    var busy = false
    var busyNs = 0
    var drops = 0

    var counters: LinkCounters { LinkCounters(busyNs: busyNs, drops: drops, queued: queue.count) }
}
```

After `func peer(_:)` add:

```swift
    /// From `a` to `b`, and back.
    func counters() -> (ab: LinkCounters, ba: LinkCounters) {
        (dirA.counters, dirB.counters)
    }
```

Replace `transmit`, `startTx`, `arrive` and `drop` (each drop is counted on its direction; serialisation time is counted when it starts):

```swift
    func transmit(from: Interface, _ frame: EthernetFrame) {
        let dir = direction(from)
        guard up else { return drop(at: from, frame, .linkDown, dir) }
        if !dir.busy { return startTx(from, dir, frame) }
        guard dir.queue.count < opts.queueLimit else { return drop(at: from, frame, .queueFull, dir) }
        dir.queue.append(frame)
    }

    private func startTx(_ from: Interface, _ dir: Direction, _ frame: EthernetFrame) {
        dir.busy = true
        sim.emit(.tx, node: from.node.id, iface: from.name, frame: frame)
        // At least 1 ns, so time always advances (a zero-time loop would never end).
        let txNs = max(1, Int((Double(frame.wireBytes * 8) * Double(S) / opts.bandwidthBps).rounded()))
        dir.busyNs += txNs
        sim.sched.after(txNs) { [self] in
            let to = peer(from)
            let lost = opts.lossRate > 0 && sim.rng.next() < opts.lossRate
            sim.sched.after(opts.propDelayNs) { [self] in arrive(to, frame, lost, dir) }
            if up, from.node.powered, !dir.queue.isEmpty {
                startTx(from, dir, dir.queue.removeFirst())
            } else {
                dir.busy = false
                // A fault or a powered-off sender loses what was waiting, and says so.
                for queued in dir.queue { drop(at: from, queued, up ? .ifaceDown : .linkDown, dir) }
                dir.queue.removeAll()
            }
        }
    }

    private func arrive(_ to: Interface, _ frame: EthernetFrame, _ lost: Bool, _ dir: Direction) {
        if lost { return drop(at: to, frame, .loss, dir) }
        guard up, to.up, to.node.powered else { return drop(at: to, frame, .linkDown, dir) }
        sim.emit(.rx, node: to.node.id, iface: to.name, frame: frame)
        to.node.receive(frame, on: to)
    }

    private func drop(at iface: Interface, _ frame: EthernetFrame, _ reason: DropReason, _ dir: Direction) {
        dir.drops += 1
        sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: frame, reason: reason)
    }
```

`Sources/PacEngine/Runtime/Protocol.swift`:

In `enum Command`, after `case nslookup(node: String, name: String)` add:

```swift
    /// Discard sink on TCP/UDP port 9 (servers only).
    case setSink(node: String, on: Bool)
    /// iperf3-style transfer of `bytes` to the target's sink.
    case trafficTcp(node: String, target: String, bytes: Int)
    /// iperf3-style constant-bitrate UDP stream to the target's sink.
    case trafficUdp(node: String, target: String, bitsPerSecond: Double, seconds: Int)
```

and in `key` after `case .nslookup: "nslookup"`:

```swift
        case .setSink: "setSink"
        case .trafficTcp: "trafficTcp"
        case .trafficUdp: "trafficUdp"
```

After `struct FlowSample { … }` add:

```swift
/// One row of a node's TCP table, netstat style.
public struct TcpRow: Equatable, Sendable {
    public let local: String
    public let remote: String
    public let state: String
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
```

In `NodeView`, after `public let dnsCache: [DnsCacheRow]` add:

```swift
    /// Discard sink on TCP/UDP port 9.
    public let sink: Bool
    /// Listening ports, then connections.
    public let tcp: [TcpRow]
```

In `AppView`, after `public let done: Bool` add:

```swift
    /// One point per 100 ms for traffic flows; empty for the other apps.
    public let samples: [FlowSample]
```

In `Snapshot`, after `public let warnings: [WarningView]` add:

```swift
    /// Per cable id, one point per 100 ms of simulated time (the last minute).
    public let linkSamples: [String: [LinkSample]]
```

and `empty` becomes:

```swift
    public static let empty = Snapshot(version: 0, seed: 1, timeNs: 0, running: true, speed: 1, mode: .realtime, epoch: 0,
                                       eventCount: 0, nodes: [], links: [], apps: [], warnings: [], linkSamples: [:])
```

`TopologyNode`: add `public var sink: Bool` after `public var dns: [DnsRecord]?`; the memberwise `init` gains a last parameter `sink: Bool = false` (`self.sink = sink`); the decoder gains `sink = try c.decodeIfPresent(Bool.self, forKey: .sink) ?? false` and its doc comment becomes `/// Files written before M2b have no \`powered\`, before M3 no services, before M4 no \`sink\`.`

`Sources/PacEngine/Runtime/Runtime.swift`:

Replace `enum Program`:

```swift
private enum Program {
    case ping(Ping)
    case trace(Traceroute)
    case nslookup(NsLookup)
    case tcpFlow(TcpFlow)
    case udpFlow(UdpFlow)

    var lines: [String] {
        switch self {
        case .ping(let p): p.result.lines
        case .trace(let t): t.result.lines
        case .nslookup(let n): n.result.lines
        case .tcpFlow(let f): f.result.lines
        case .udpFlow(let f): f.result.lines
        }
    }

    var done: Bool {
        switch self {
        case .ping(let p): p.result.done
        case .trace(let t): t.result.done
        case .nslookup(let n): n.result.done
        case .tcpFlow(let f): f.result.done
        case .udpFlow(let f): f.result.done
        }
    }

    /// A traffic flow's metrics; empty for the other apps.
    var samples: [FlowSample] {
        switch self {
        case .tcpFlow(let f): f.result.samples
        case .udpFlow(let f): f.result.samples
        case .ping, .trace, .nslookup: []
        }
    }

    func stop() {
        switch self {
        case .ping(let p): p.stop()
        case .trace(let t): t.stop()
        case .nslookup(let n): n.stop()
        case .tcpFlow(let f): f.stop()
        case .udpFlow(let f): f.stop()
        }
    }

    func sample(at time: Int) {
        switch self {
        case .tcpFlow(let f): f.sample(at: time)
        case .udpFlow(let f): f.sample(at: time)
        case .ping, .trace, .nslookup: break
        }
    }
}
```

After `private func secondsLeft(_:)` add:

```swift
/// Totals → one 100 ms point of a cable direction.
// ponytail: a frame's serialisation counts whole in the interval it starts in (capped at 100%)
private func directionSample(_ c: LinkCounters, since last: LinkCounters) -> DirectionSample {
    DirectionSample(utilization: min(1, Double(c.busyNs - last.busyNs) / Double(SAMPLE_NS)), queued: c.queued, drops: c.drops - last.drops)
}
```

In `Runtime`, after `private var last: Snapshot?` add:

```swift
    /// Next 100 ms boundary at which cables and flows are sampled.
    private var nextSampleAt = SAMPLE_NS
    private var linkSamples: [String: [LinkSample]] = [:]
    /// Cable totals at the previous sample.
    private var linkCounters: [String: (ab: LinkCounters, ba: LinkCounters)] = [:]
```

In `handle`:
- `.removeNode`: inside the `for linkId in linkOrder where …` loop, after `links[linkId] = nil`, add `forget(link: linkId)`.
- `.disconnect`: after `linkOrder.removeAll { $0 == id }` add `forget(link: id)`.
- after the `.nslookup` case add:

```swift
        case let .setSink(node, on):
            let n = try ipNode(node)
            guard !on || nodes[node]?.kind == .server else { throw EngineError("\(n.name) cannot run a traffic sink") }
            try n.configureSink(on)
        case let .trafficTcp(node, target, bytes):
            let t = target.trimmingCharacters(in: .whitespaces)
            let flow = try TcpFlow(node: try liveIpNode(node), target: t, bytes: bytes)
            start(node, "iperf3 -c \(t) -p \(PORT_DISCARD) -n \(bytes)", .tcpFlow(flow))
        case let .trafficUdp(node, target, bitsPerSecond, seconds):
            let t = target.trimmingCharacters(in: .whitespaces)
            // Validated first: the title converts the rate to an integer.
            let flow = try UdpFlow(node: try liveIpNode(node), target: t, bitsPerSecond: bitsPerSecond, seconds: seconds)
            start(node, "iperf3 -u -c \(t) -p \(PORT_DISCARD) -b \(Int(bitsPerSecond)) -t \(seconds)", .udpFlow(flow))
```

In `advance`, the realtime branch becomes:

```swift
        case .realtime:
            run(until: sim.now + Int((min(wallMs, MAX_STEP_MS) * Double(MS) * speed).rounded()), maxEvents: MAX_EVENTS_PER_ADVANCE)
```

Replace `step()` and add the run loop, the sampler and `forget(link:)`:

```swift
    /// Runs scheduled events until one is logged (a frame sent, received or dropped) or none are left,
    /// sampling every 100 ms boundary passed on the way.
    private func step() {
        let before = sim.log.total
        var budget = MAX_SILENT_EVENTS
        while sim.log.total == before, budget > 0, let next = sim.sched.nextTime {
            // An idle stretch longer than the kept history would only produce points that get thrown away.
            nextSampleAt = max(nextSampleAt, (next - 1) / SAMPLE_NS * SAMPLE_NS - (METRICS_HISTORY - 1) * SAMPLE_NS)
            while nextSampleAt < next { sample() }
            sim.sched.step()
            budget -= 1
        }
    }

    /// Runs events up to `time` (at most `maxEvents`), stopping at every 100 ms boundary to sample cables and flows there.
    private func run(until time: Int, maxEvents: Int) {
        var budget = maxEvents
        while budget > 0 {
            let stop = min(time, nextSampleAt)
            budget -= sim.sched.runUntil(stop, maxEvents: budget)
            guard sim.now == stop else { return } // out of budget: the clock stays at the last event run
            if stop == nextSampleAt { sample() }
            if stop == time { return }
        }
    }

    /// One point for every cable and running traffic flow, stamped at the boundary.
    private func sample() {
        let at = nextSampleAt
        nextSampleAt += SAMPLE_NS
        for id in linkOrder {
            let now = links[id]!.counters()
            let last = linkCounters[id] ?? (LinkCounters(), LinkCounters())
            linkCounters[id] = now
            linkSamples[id, default: []].append(LinkSample(timeNs: at, ab: directionSample(now.ab, since: last.ab),
                                                           ba: directionSample(now.ba, since: last.ba)))
            if linkSamples[id]!.count > METRICS_HISTORY { linkSamples[id]!.removeFirst() }
        }
        for app in apps where !app.program.done { app.program.sample(at: at) }
    }

    private func forget(link id: String) {
        linkSamples[id] = nil
        linkCounters[id] = nil
    }

    /// netstat -ant: listening ports, then connections in the order they were opened.
    private func tcpRows(_ n: IpNode) -> [TcpRow] {
        n.tcp.listening.map { TcpRow(local: "0.0.0.0:\($0)", remote: "0.0.0.0:*", state: "LISTEN") }
            + n.tcp.connections.map {
                TcpRow(local: "\(formatIp($0.localIp)):\($0.localPort)", remote: "\(formatIp($0.remoteIp)):\($0.remotePort)", state: $0.state.rawValue)
            }
    }
```

In `build()`:
- the `NodeView(…)` call gains two last arguments after the `dnsCache: …` one:

```swift
                sink: ip?.sink ?? false,
                tcp: ip.map { tcpRows($0) } ?? []
```
- `appViews` becomes:

```swift
        let appViews = apps.map {
            AppView(id: $0.id, node: $0.node, title: $0.title, lines: $0.program.lines, done: $0.program.done, samples: $0.program.samples)
        }
```

- the `Snapshot(…)` call ends `warnings: sim.warnings.map { WarningView(id: $0.id, node: $0.node, timeNs: $0.time) }, linkSamples: linkSamples)`.

In `load(_:)`:
- in the services loop, after `if let records = n.dns { … }` add `if n.sink { try next.handle(.setSink(node: n.id, on: true)) }`.
- after `stepCredit = 0` add:

```swift
        nextSampleAt = SAMPLE_NS
        linkSamples = [:]
        linkCounters = [:]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (6 more than before this task; the existing Runtime clock/step tests still pass — sampling never moves the clock).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Sources/PacEngine/Link.swift Sources/PacEngine/Scheduler.swift Tests/PacEngineTests/RuntimeTrafficTests.swift
git commit -m "feat(engine): expose traffic commands, the sink and TCP tables, sample cables and flows every 100 ms

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: PacKit — generator fields, bottom tab, metric formatting, saving the sink

**Files:**
- Modify: `Sources/PacKit/Topology+Helpers.swift`, `Sources/PacKit/Editor.swift`
- Create: `Tests/PacKitTests/TrafficEditorTests.swift`
- Modify test: `Tests/PacKitTests/HelpersTests.swift`

**Interfaces:**
- Consumes: Task 5 commands and views, Task 4 `FlowSample`.
- Produces: `public enum BottomTab: String, CaseIterable { events="Eventi", output="Output app", metrics="Metriche" }`; `public enum TrafficKind: String, CaseIterable { tcp="TCP", udp="UDP" }`; `Editor.bottomTab: BottomTab` (default `.events`); `Editor.startTraffic(_:target:kind:amount:seconds:) async` (errors under `"app:<node>"`); `public func flowSummary(_: FlowSample) -> String`; `public func directionSummary(_: DirectionSample) -> String`; `makeTopology` saves `sink`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacKitTests/TrafficEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct TrafficEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    /// SRV1 (10.0.0.2/24, sink on) cabled to PC1 (10.0.0.1/24).
    private func pair() async -> (srv: String, pc: String) {
        await editor.addDevice(.server, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 100, y: 0))
        let (srv, pc) = (node("SRV1").id, node("PC1").id)
        await editor.connect(srv, pc)
        await editor.edit(.setIp(node: srv, iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.edit(.setIp(node: pc, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setSink(node: srv, on: true))
        return (srv, pc)
    }

    @Test func startsTrafficFromTheAppTabFieldsAndShowsTypingErrorsThere() async {
        let (_, pc) = await pair()
        let key = "app:\(pc)"
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .tcp, amount: "1e6", seconds: "")
        #expect(editor.error == EditorError(key: key, message: "Invalid number: \"1e6\""))
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .udp, amount: "1,5", seconds: "dieci")
        #expect(editor.error == EditorError(key: key, message: "Invalid number: \"dieci\""))
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .udp, amount: "5000", seconds: "2")
        #expect(editor.error == EditorError(key: key, message: "Bitrate must be between 1 kb/s and 1 Gb/s"))
        #expect(editor.snapshot.apps.isEmpty)
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .tcp, amount: " 100000 ", seconds: "")
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .udp, amount: "1,5", seconds: "2")
        #expect(editor.error == nil)
        #expect(editor.snapshot.apps.map(\.title) == ["iperf3 -c 10.0.0.2 -p 9 -n 100000", "iperf3 -u -c 10.0.0.2 -p 9 -b 1500000 -t 2"])
        #expect(editor.bottomTab == .events)
    }

    @Test func theSinkIsOneUndoStepAndIsSaved() async {
        let (srv, _) = await pair()
        #expect(node("SRV1").sink)
        #expect(editor.current.nodes.first { $0.id == srv }?.sink == true)
        await editor.undo()
        #expect(!node("SRV1").sink)
    }
}
```

Append inside `struct HelpersTests` in `Tests/PacKitTests/HelpersTests.swift`:

```swift
    @Test func formatsTheLatestFlowAndCableMetrics() {
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 9_492_848, delayNs: 1_234_567, jitterNs: nil, lossPct: 1.5))
            == "9.49 Mb/s · RTT 1.235 ms · perdita 1.5%")
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 1_011_360, delayNs: 1_229_300, jitterNs: 2_600, lossPct: 0))
            == "1.01 Mb/s · latenza 1.229 ms · jitter 0.003 ms · perdita 0.0%")
        #expect(flowSummary(FlowSample(timeNs: 0, bitsPerSecond: 0, delayNs: nil, jitterNs: nil, lossPct: 0)) == "0.00 Mb/s · perdita 0.0%")
        #expect(directionSummary(DirectionSample(utilization: 0.946, queued: 12, drops: 3)) == "95% · coda 12 · drop 3")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `startTraffic`, `bottomTab`, `flowSummary`, `directionSummary` unknown.

- [ ] **Step 3: Implement**

`Sources/PacKit/Topology+Helpers.swift`:

After `inspectorTabs(for:)` add:

```swift
/// Bottom panel tabs (spec §7.1 ⑤).
public enum BottomTab: String, CaseIterable, Sendable {
    case events = "Eventi", output = "Output app", metrics = "Metriche"
}

/// The App tab's traffic generator modes.
public enum TrafficKind: String, CaseIterable, Sendable {
    case tcp = "TCP", udp = "UDP"
}
```

In `makeTopology`, the `TopologyNode(…)` call ends `dns: n.dnsRecords, sink: n.sink)`.

At the end of the file add:

```swift
private func milliseconds(_ ns: Int) -> String {
    String(format: "%.3f ms", Double(ns) / 1e6)
}

/// A flow's latest point: "9.49 Mb/s · RTT 1.235 ms · perdita 1.5%" (TCP) or with one-way latency and jitter (UDP).
public func flowSummary(_ s: FlowSample) -> String {
    var parts = [String(format: "%.2f Mb/s", s.bitsPerSecond / 1e6)]
    if let d = s.delayNs { parts.append((s.jitterNs == nil ? "RTT " : "latenza ") + milliseconds(d)) }
    if let j = s.jitterNs { parts.append("jitter " + milliseconds(j)) }
    parts.append(String(format: "perdita %.1f%%", s.lossPct))
    return parts.joined(separator: " · ")
}

/// One direction of a cable: "95% · coda 12 · drop 3".
public func directionSummary(_ d: DirectionSample) -> String {
    "\(Int((d.utilization * 100).rounded()))% · coda \(d.queued) · drop \(d.drops)"
}
```

`Sources/PacKit/Editor.swift`:

After `public var inspectorTab: InspectorTab?` add:

```swift
    /// Bottom panel tab; "Mostra metriche" on a cable switches it to Metriche.
    public var bottomTab = BottomTab.events
```

After `removeDnsRecord(_:at:)` add:

```swift
    /// Starts the App tab's generator: TCP sends `amount` bytes; UDP sends `amount` Mb/s for `seconds`. Errors show under the App tab.
    public func startTraffic(_ id: String, target: String, kind: TrafficKind, amount: String, seconds: String) async {
        await serialized {
            let key = "app:\(id)"
            let number = amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let cmd: Command
            switch kind {
            case .tcp:
                guard let bytes = Int(number) else { return self.fail(key, EngineError("Invalid number: \"\(amount)\"")) }
                cmd = .trafficTcp(node: id, target: target, bytes: bytes)
            case .udp:
                guard let mbps = Double(number), mbps.isFinite else { return self.fail(key, EngineError("Invalid number: \"\(amount)\"")) }
                guard let s = Int(seconds.trimmingCharacters(in: .whitespaces)) else {
                    return self.fail(key, EngineError("Invalid number: \"\(seconds)\""))
                }
                cmd = .trafficUdp(node: id, target: target, bitsPerSecond: mbps * 1e6, seconds: s)
            }
            _ = await self.runNow(cmd, key: key)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (3 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacKit/Topology+Helpers.swift Sources/PacKit/Editor.swift Tests/PacKitTests/TrafficEditorTests.swift Tests/PacKitTests/HelpersTests.swift
git commit -m "feat(kit): start traffic from typed fields, keep the bottom tab, format metrics, save the sink

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: App — traffic generator, sink toggle, TCP table, Metriche panel, "Mostra metriche", selftest

**Files:**
- Create: `Sources/PacTrack/MetricsPanel.swift`
- Modify: `Sources/PacTrack/BottomPanel.swift`, `Sources/PacTrack/InspectorView.swift`, `Sources/PacTrack/ServicesTab.swift`, `Sources/PacTrack/CanvasView.swift`, `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: Task 6 (`BottomTab`, `TrafficKind`, `Editor.bottomTab`, `Editor.startTraffic`, `flowSummary`, `directionSummary`), Task 5 (`.setSink`, `NodeView.sink`, `NodeView.tcp`, `AppView.samples`, `Snapshot.linkSamples`).

- [ ] **Step 1: Baseline image**

Run: `scripts/selftest.sh build/m4-before.png` → `SELFTEST OK`; Read `build/m4-before.png` (bottom panel: Eventi | Output app; the event filters already show a TCP chip from Task 1).

- [ ] **Step 2: Write the failing selftest scenario**

In `Sources/PacTrack/SelfTest.swift`, in `scenario(output:)` after `failures += await servicesScenario(output: output)` add:

```swift
        failures += await trafficScenario(output: output)
```

and add to `SelfTest`:

```swift
    /// M4: SRV1 runs the sink behind a 10 Mb/s cable; PC1 sends 1 MB over TCP and PC2 1 Mb/s of UDP for 2 s.
    private static func trafficScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.server, at: Pos(x: 560, y: 360))
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.pc, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        for name in ["SRV1", "PC1", "PC2"] { await editor.connect(id("SW1"), id(name)) }
        for (name, cidr) in [("SRV1", "10.0.0.2/24"), ("PC1", "10.0.0.10/24"), ("PC2", "10.0.0.11/24")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
        }
        let cable = editor.snapshot.links[0].id // a = SW1, b = SRV1
        await editor.setLink(cable, .bandwidth, "10")
        await editor.edit(.setSink(node: id("SRV1"), on: true))
        await editor.startTraffic(id("PC1"), target: "10.0.0.2", kind: .tcp, amount: "1000000", seconds: "")
        await editor.startTraffic(id("PC2"), target: "10.0.0.2", kind: .udp, amount: "1", seconds: "2")
        for _ in 0..<40 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if apps.map({ $0.lines.last }) != ["iperf Done.", "iperf Done."] { failures.append("traffic output \(apps.map(\.lines))") }
        if !(apps.last?.lines.contains { $0.hasSuffix("0/171 (0%)") } ?? false) { failures.append("UDP report \(apps.last?.lines ?? [])") }
        if apps.contains(where: { $0.samples.isEmpty }) { failures.append("a flow has no metrics") }
        let peak = editor.snapshot.linkSamples[cable]?.map(\.ab.utilization).max() ?? 0
        if peak < 0.9 { failures.append("SW1 → SRV1 peak utilisation \(peak)") }
        if editor.snapshot.nodes.first(where: { $0.name == "SRV1" })?.tcp.first?.state != "LISTEN" { failures.append("SRV1 TCP table") }
        editor.select(.link(cable))
        editor.bottomTab = .metrics
        if !render(editor, to: sibling(output, "m4")) { failures.append("could not write the M4 metrics image") }
        editor.select(.node(id("PC1")))
        editor.inspectorTab = .app
        editor.bottomTab = .output
        if !render(editor, to: sibling(output, "m4-app")) { failures.append("could not write the M4 app image") }
        return failures
    }
```

- [ ] **Step 3: Run it to verify the engine checks pass but the images lack the UI**

Run: `scripts/selftest.sh build/selftest.png`
Expected: `SELFTEST OK` (engine and editor already work); Read `build/selftest-m4.png`: the bottom panel still shows Eventi (no Metriche tab) — the RED for this UI task is visual, as in M3.

- [ ] **Step 4: Implement the UI**

Replace `Sources/PacTrack/BottomPanel.swift`:

```swift
import PacKit
import SwiftUI

/// Resizable panel under the canvas (spec §7.1 ⑤).
struct BottomPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $editor.bottomTab) { ForEach(BottomTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch editor.bottomTab {
            case .events: EventsPanel(editor: editor)
            case .output: OutputPanel(editor: editor)
            case .metrics: MetricsPanel(editor: editor)
            }
        }
        .background(Theme.panel)
    }
}
```

Create `Sources/PacTrack/MetricsPanel.swift`:

```swift
import Charts
import PacEngine
import PacKit
import SwiftUI

/// Metriche tab (spec §5.6): the selected cable per direction and every traffic flow, one point per 100 ms of simulated time.
struct MetricsPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { link.padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            ScrollView { flows.padding(10).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(Theme.mono)
        .background(Theme.panel)
        .accessibilityIdentifier("metrics")
    }

    private func name(_ id: String) -> String {
        editor.snapshot.nodes.first { $0.id == id }?.name ?? "(rimosso)"
    }

    @ViewBuilder
    private var link: some View {
        if case .link(let id) = editor.selection, let l = editor.snapshot.links.first(where: { $0.id == id }),
           let samples = editor.snapshot.linkSamples[id], let last = samples.last {
            let ab = "\(name(l.a.node)) → \(name(l.b.node))"
            let ba = "\(name(l.b.node)) → \(name(l.a.node))"
            VStack(alignment: .leading, spacing: 4) {
                Text("UTILIZZO DEL COLLEGAMENTO (%)").font(.system(size: 9)).foregroundStyle(Theme.muted)
                Chart {
                    ForEach(samples, id: \.timeNs) { s in
                        LineMark(x: .value("Tempo (s)", Double(s.timeNs) / 1e9), y: .value("Utilizzo", s.ab.utilization * 100),
                                 series: .value("Verso", ab))
                            .foregroundStyle(by: .value("Verso", ab))
                        LineMark(x: .value("Tempo (s)", Double(s.timeNs) / 1e9), y: .value("Utilizzo", s.ba.utilization * 100),
                                 series: .value("Verso", ba))
                            .foregroundStyle(by: .value("Verso", ba))
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 120)
                Text("\(ab): \(directionSummary(last.ab))")
                Text("\(ba): \(directionSummary(last.ba))")
            }
        } else {
            Text("Seleziona un collegamento (o «Mostra metriche» dal suo menu) per vederne utilizzo, coda e drop.")
                .foregroundStyle(Theme.muted)
        }
    }

    private var flows: some View {
        let apps = editor.snapshot.apps.filter { !$0.samples.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            if apps.isEmpty {
                Text("Nessun flusso: avvia il generatore di traffico dalla scheda App di un host.").foregroundStyle(Theme.muted)
            }
            ForEach(apps) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name(app.node))$ \(app.title)").foregroundStyle(Theme.accent)
                    Chart(app.samples, id: \.timeNs) { s in
                        LineMark(x: .value("Tempo (s)", Double(s.timeNs) / 1e9), y: .value("Mb/s", s.bitsPerSecond / 1e6))
                    }
                    .frame(height: 80)
                    if let last = app.samples.last { Text(flowSummary(last)) }
                }
            }
        }
    }
}
```

`Sources/PacTrack/InspectorView.swift`:

In `tables`, after the `TableSection(title: "Cache ARP", …)` line add:

```swift
                TableSection(title: "Connessioni TCP", head: ["Locale", "Remoto", "Stato"], rows: node.tcp.map { [$0.local, $0.remote, $0.state] })
```

Replace `AppTab`:

```swift
private struct AppTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var target = ""
    @State private var kind = TrafficKind.tcp
    @State private var amount = "1000000"
    @State private var seconds = "10"

    var body: some View {
        let key = "app:\(node.id)"
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinazione").font(Theme.small).foregroundStyle(Theme.muted)
            TextField("10.0.0.2 o nome host", text: $target).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("app-target")
            HStack {
                Button("Ping") { Task { await editor.run(.ping(node: node.id, target: target), key: key) } }
                Button("Traceroute") { Task { await editor.run(.traceroute(node: node.id, target: target), key: key) } }
                Button("nslookup") { Task { await editor.run(.nslookup(node: node.id, name: target), key: key) } }
            }
            ErrorLine(editor: editor, key: key)
            Text("L'output compare nel pannello in basso.").font(Theme.small).foregroundStyle(Theme.muted)
            Divider()
            Text("GENERATORE DI TRAFFICO").font(.system(size: 9)).foregroundStyle(Theme.muted)
            Picker("", selection: $kind) { ForEach(TrafficKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: kind) { _, k in amount = k == .tcp ? "1000000" : "1" }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .tcp ? "Byte da inviare" : "Bitrate (Mb/s)").font(Theme.small).foregroundStyle(Theme.muted)
                    TextField("", text: $amount).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("traffic-amount")
                }
                if kind == .udp {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Durata (s)").font(Theme.small).foregroundStyle(Theme.muted)
                        TextField("", text: $seconds).textFieldStyle(.roundedBorder).font(Theme.mono).frame(width: 60)
                    }
                }
            }
            Button("Avvia traffico") {
                Task { await editor.startTraffic(node.id, target: target, kind: kind, amount: amount, seconds: seconds) }
            }
            .accessibilityIdentifier("traffic-start")
            Text("Destinazione: un server con il sink attivo (Servizi). Risultati in Output app e Metriche.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }
}
```

`Sources/PacTrack/ServicesTab.swift` — the body's `if node.kind == .server { dns }` becomes:

```swift
            if node.kind == .server {
                dns
                sink
            }
```

and add to `ServicesTab`:

```swift
    private var sink: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Sink TCP/UDP (porta 9)", isOn: Binding(get: { node.sink }, set: { on in
                Task { await editor.edit(.setSink(node: node.id, on: on)) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("sink-enabled")
            Text(node.sink ? "Riceve e scarta il traffico del generatore." : "Spento: TCP risponde con RST, UDP con ICMP port unreachable.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }
```

`Sources/PacTrack/CanvasView.swift` — in the cable's `.contextMenu`, after `Button("Proprietà") { … }` add:

```swift
            Button("Mostra metriche") {
                editor.select(.link(link.id))
                editor.bottomTab = .metrics
            }
```

- [ ] **Step 5: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m4.png` (bottom panel on Metriche: left the SW1 → SRV1 / SRV1 → SW1 utilisation chart with the 10 Mb/s direction near 100 % then dropping, the two summary lines; right two flow charts with their `Mb/s · RTT …` and `Mb/s · latenza … · jitter …` lines; event chips include TCP in green) and `build/selftest-m4-app.png` (PC1 App tab with the generator section, Output app with both iperf3 transcripts ending `iperf Done.`). If the chart legend or the generator row overflows the 300 pt inspector or the panel height, tighten the frames (`.chartLegend(position: .top)`, smaller `height`) and re-check. Also `scripts/test.sh` stays green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PacTrack/MetricsPanel.swift Sources/PacTrack/BottomPanel.swift Sources/PacTrack/InspectorView.swift Sources/PacTrack/ServicesTab.swift Sources/PacTrack/CanvasView.swift Sources/PacTrack/SelfTest.swift
git commit -m "feat(app): add the traffic generator, sink toggle, TCP connection table, Metriche panel and Mostra metriche

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Manual checklist and bundle

**Files:**
- Create: `docs/manual-checks/m4.md`

- [ ] **Step 1: Write the checklist**

```markdown
# M4 — manual checks

Build and open: `scripts/bundle.sh && open build/PacTrack.app`. Start from a switch SW1 with a Server SRV1 (10.0.0.2/24) and two PCs, PC1 (10.0.0.10/24) and PC2 (10.0.0.11/24); set the SW1–SRV1 cable to 10 Mb/s.

**Sink and TCP**
- [ ] SRV1 ▸ Servizi ▸ *Sink TCP/UDP (porta 9)* on; Tabelle ▸ *Connessioni TCP* shows `0.0.0.0:9  0.0.0.0:*  LISTEN`. Cmd+Z turns it off again (one step).
- [ ] With the sink off, PC1 ▸ App ▸ `10.0.0.2` ▸ TCP ▸ *Avvia traffico*: Output shows `iperf3: error - unable to connect to server: Connection refused`; the event list shows `[SYN]` then `[RST, ACK]` in green.
- [ ] Sink on, TCP 1000000 bytes: `Connecting to host 10.0.0.2, port 9`, `[  1] local 10.0.0.10 port … connected to 10.0.0.2 port 9`, then `0.00-0.8x sec  1000000 bytes  9.4x Mbits/sec  0 retr` and `iperf Done.`
- [ ] Event list, TCP only: `[SYN] … mss=1460`, `[SYN, ACK]`, `[ACK]`, data `len=1460`, ACKs, `[FIN, ACK]`, `[FIN, ACK]`, `[ACK]`. Click the SYN: Ethernet / IPv4 (protocol 6) / TCP with ports, sequence and ack numbers, header 24 B, flags 0x002 (SYN), window 65535, checksum, *Opzione MSS 1460 B*; frame 58 B. A data frame is 1514 B.
- [ ] PC1 ▸ Tabelle ▸ *Connessioni TCP*: right after the transfer the connection is `TIME_WAIT`; it disappears 60 s later.
- [ ] Simulation mode, step through a TCP transfer: SYN, SYN-ACK, ACK, then three data segments leave PC1 before the first ACK is back (initial window 3 × MSS).
- [ ] SW1–SRV1 loss 1 %: the transfer still completes with some `retr`; the event list shows a `seq=` sent twice — soon after three duplicate ACKs (fast retransmit) or ≥ 1 s later (timeout).
- [ ] Switch SRV1 off during a 100000000-byte transfer: PC1 repeats the same segment at growing intervals (1, 2, 4 … s); after about 2 minutes `iperf3: error - Connection timed out`. Switching SRV1 back on before that gives `iperf3: error - Connection reset by peer` instead.
- [ ] Switch PC1 off mid-transfer: `iperf3: interrupt - the client has terminated`.

**UDP**
- [ ] PC2 ▸ App ▸ UDP, 1 Mb/s, 10 s: after ~11 s `… 1.00 Mbits/sec  0.000 ms  0/851 (0%)` and `iperf Done.`; UDP frames of 1512 B to port 9; the PDU's data line reads `1470 B (generatore di traffico, seq …)`.
- [ ] Sink off: SRV1 answers ICMP port unreachable and the report ends `851/851 (100%)`.
- [ ] SW1–SRV1 queue 10 frames, UDP 20 Mb/s for 5 s: about half lost.
- [ ] App tab: `abc` as bytes, `0` as duration or `5000` Mb/s show an error under the App tab and start nothing.

**Metriche**
- [ ] Right-click the SW1–SRV1 cable ▸ *Mostra metriche*: the bottom panel switches to Metriche with a utilisation chart per direction (SW1 → SRV1, SRV1 → SW1) and the lines `…% · coda … · drop …`.
- [ ] During the TCP transfer SW1 → SRV1 sits near 100 % and SRV1 → SW1 near 5 % (ACKs); during the 20 Mb/s UDP stream the queue reads 10 and the drops grow.
- [ ] Each flow shows a throughput chart and `Mb/s · RTT … · perdita …%` (TCP) or `Mb/s · latenza … · jitter … · perdita …%` (UDP); at 10× speed the charts still have a point every 100 ms of simulated time.
- [ ] Cmd+Z after a transfer (the network reloads): the charts start over.
- [ ] Save, close, reopen: SRV1's sink is still on.
```

- [ ] **Step 2: Full verification**

Run: `scripts/test.sh 2>&1 | tail -3` (all pass), `scripts/selftest.sh build/selftest.png` (`SELFTEST OK`), `scripts/bundle.sh`, then launch `build/PacTrack.app/Contents/MacOS/PacTrack` in the background for ~5 s, confirm it is running (`pgrep -x PacTrack`) and its log is empty, kill it.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-checks/m4.md
git commit -m "docs: add the M4 manual checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Out of scope (recorded)

- TCP: delayed ACK, SACK, timestamps, window scaling, PSH/Nagle beyond "full segments only", NewReno partial ACKs (RFC 6582), persist timer and zero-window probes, keepalive, FIN_WAIT_2 timeout, simultaneous open, CLOSING as a state, TIME_WAIT restart, RFC 5961 RST checks, ICMP errors aborting a connection (Linux reports "No route to host" in SYN_SENT; here the SYN times out).
- Echo service, a configurable sink port, generator datagram size, per-second iperf3 interval lines, stopping one app (power off stops it) — added when a lab or user flow needs them.
- Wireshark-style relative sequence numbers; a queue-length chart (queue and drops show as text).
- A "Traffico verso ▸" node context-menu entry (spec §7.2 does not list it).
