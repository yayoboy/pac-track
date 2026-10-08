# M5 — NAT and firewall (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Routers translate and filter like real ones: NAT/PAT (IOS `ip nat inside`/`ip nat outside` + overload on the outside address) with a translation table and the spec's timeouts (TCP 7440 s, UDP 300 s, ICMP 60 s), ICMP echo identifiers and ICMP errors translated back to the inside host, every checksum right; and a stateful firewall with ordered rules bound to an interface and a direction (allow/deny on protocol, address/prefix, destination port), first match wins, a default policy, replies and related ICMP errors let back in, every refusal a visible drop event with its reason. The Servizi tab configures both, Tabelle shows the translations.

**Architecture:** `PacEngine` gains flow helpers in `PDU.swift` (`Endpoints`, packet rewriting with recomputed checksums, the ICMP-error quote rewrite), a `Nat` (`L3/Nat.swift`: extended entries with lazy expiry, endpoint-independent mapping, port preservation) and a `Firewall` (`L3/Firewall.swift`: compiled rules, flow state with lazy expiry) owned by `IpNode` and hooked into its `input`/`output` path in netfilter order (NAT outside → inside, routing, filter, NAT inside → outside; packets for the router filtered on the way in; the router's own packets never). The `Runtime` adds `setNat`/`setFirewall`, the NAT table and both configurations to `NodeView`, and the `nat`/`firewall` node keys in `.ptk`. `PacKit` adds NAT roles and firewall rule editing (one undo step each); `PacTrack` adds the NAT and Firewall sections to Servizi and "Traduzioni NAT" to Tabelle.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM — Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2: §3 MVP "NAT/PAT, firewall stateful", §5.4 NAT/PAT and Firewall rows, §5.5 Router "NAT, firewall attivabili", §6, §7.1 ④ Tabelle "NAT" and Servizi "NAT, firewall", §8, §9, §10 "NAT PAT inside→outside e ritorno · firewall deny/allow e stateful" — milestone M5). Conventions: `docs/superpowers/plans/2026-10-08-m4-tcp-traffic-metrics.md`; rulings ledger style: `.superpowers/sdd/2026-10-08-m4-tcp-traffic-metrics/progress.md`.

## Global Constraints

- Run every `swift`/`scripts/*.sh` command **outside the sandbox**; unit tests only via `scripts/test.sh` (bare `swift test` runs zero tests with CLT). End-to-end: `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`.
- Work in place on branch `rewrite/v3`; never switch branches or create worktrees. An M4 review fix pass may be touching TCP, flows and sampling concurrently: **stage only the files a task lists** (`git add <paths>`), do not edit `L4/Tcp.swift`, `Apps/Traffic.swift`, `Link.swift`, `Scheduler.swift`, `MetricsPanel.swift` or their tests, and in `Runtime.swift` touch only the spots a task names. M4 is used only through its public surface (`TcpFlow`, `UdpFlow`, their `result.lines`, `configureSink`).
- The UI never holds engine objects — only `Snapshot` values and string ids.
- Never store `SimTimer`s: NAT translations and firewall flows carry an `expiresAt` and are dropped lazily when read (no timers at all). Removed nodes stay alive until the Sim is replaced.
- No randomness added (port choice is deterministic); never iterate a `Dictionary` on the simulation path — tables are arrays, oldest first.
- Every network change goes through `Editor.edit` (one undo step: a NAT role, a firewall toggle, a default policy, a rule added or removed). Snapshot `version` stays stable while nothing changes.
- `.ptk`: `Topology.version` stays `1`; new optional node keys `nat` and `firewall` (missing ⇒ off). Translations and firewall flows are never saved.
- Protocol constants: translation/flow idle timeouts TCP 7440 s, UDP 300 s, ICMP 60 s; TCP 60 s after a FIN or RST; a new mapping keeps the inside port (ICMP: identifier) if free, else the next free one above it, wrapping to 1024.
- User-facing copy Italian; engine error messages English (as M3/M4); code, comments, tests, commits English. Colours only via `Theme`.
- Ponytail: nothing for M6 (no export, packaging, README, legacy removal); every API below has a consumer in this plan; deliberate shortcuts carry a `ponytail:` comment naming the ceiling.
- Commit trailer (exactly this line, after a blank line):
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

## Review Focus

1. **Ping or traceroute from an inside host through NAT** → the echo identifier comes back, and every ICMP error about a translated packet (Time Exceeded beyond the router, Port Unreachable from the target) reaches the inside host with its quoted packet translated back, or traceroute shows `*` forever. Pinned: `pingAndTracerouteFromInsideWorkAndIcmpErrorsComeBackTranslated`.
2. **Unsolicited traffic to the outside address, or a reply from the wrong remote endpoint** → it is the router's own (ping answered, TCP RST, UDP port unreachable) and never leaks to an inside host. Pinned: `unsolicitedPacketsToTheOutsideAddressAreTheRoutersOwnAndAPowerCycleClearsTheTable`, `twoHostsOnTheSamePortGetDifferentGlobalPortsAndOnlyTheContactedEndpointGetsBack`.
3. **A default-deny firewall** → replies to allowed flows and ICMP errors about them (traceroute) still pass; outside-initiated traffic and traffic to the router itself are dropped with `firewall-default`. Pinned: `withADefaultDenyOnlyRepliesAndErrorsAboutAllowedFlowsGetBack`.
4. **NAT and a default-deny firewall on the same router** → state must match the reply after NAT has put the inside address back, or every connection dies. Pinned: `showsTranslationsAndDropsAndForgetsTranslationsOnAPowerCycle`.
5. **Power cycle, reconfiguration, undo, reload of an older file** → translations and flows are forgotten, configuration kept, M4 files open with NAT and firewall off. Pinned: same test, `loadsNatAndFirewallAndOpensOlderFilesWithoutThem`, `natRolesAllowOneOutsideAndNoRolesTurnNatOff`.

## Rulings (where the spec is silent)

Each line: ruling — why — cost if wrong.

- NAT is IOS PAT on the outside interface's address (`ip nat inside source list … interface Gi0/x overload`): every TCP, UDP and ICMP echo request entering an inside interface and routed out of the outside one is translated; one outside interface; no pools, no source ACL, no static NAT or port forwarding — the spec lists source translation with ports only — a lab needing a reachable inside server needs static NAT (added when one asks).
- Endpoint-independent mapping (RFC 4787 REQ-1: an inside endpoint keeps its global port for every remote) with address-and-port-dependent filtering (one IOS "extended" entry per remote endpoint; only that endpoint gets back in) — the RFC's required mapping and the Linux/IOS filtering — full-cone labs would need endpoint-independent filtering.
- Port choice: the inside port (ICMP: the echo identifier) if free on the outside address, else the next free one above it, wrapping to 1024 — Linux and IOS preserve the port; deterministic, no PRNG draw — IOS's port-range classes (0–511, 512–1023) are not kept.
- Timeouts as the spec (TCP 7440 s = RFC 5382 REQ-5, UDP 300 s = RFC 4787 REQ-5, ICMP 60 s = RFC 5508's minimum), plus IOS `finrst-timeout` 60 s once a FIN or RST went by; only the flow's own packets refresh an entry, ICMP errors never do — IOS defaults — a FIN-closed TCP row disappears after a minute, not two hours.
- Unmatched packets arriving on the outside interface are left alone: addressed to the outside address they are the router's own (it answers ping, sends RST or port unreachable), otherwise they are routed untranslated — IOS: NAT is not a filter — none.
- ICMP errors about a translated packet are translated back with their quoted packet (RFC 5508 §4, RFC 3022 §4.3): outer destination, quoted source address and port/identifier; checksums: IPv4 header and TCP recomputed in full (same result as RFC 1624), UDP's stays 0 (not computed, RFC 768), quoted IPv4 header recomputed, quoted ICMP echo checksum adjusted (RFC 1624) — none.
- Echo replies and ICMP errors sent by inside hosts leave untranslated (they only arise when an outside host reaches an inside one through an untranslated route) — no consumer in M5 — such a reply shows the private source.
- Any NAT or firewall reconfiguration, and a power cycle, forget translations and flows (`clear ip nat translation *`); configuration stays — simplest correct reset — none.
- Firewall model: one ordered rule list per router, each rule bound to an interface and a direction (`in`/`out`), matching protocol (any/ICMP/TCP/UDP), source and destination (`any`, an address or a prefix) and one destination port (TCP/UDP only); one default policy for packets no rule matches; enabling starts with no rules and `allow` (nothing breaks when switched on) — the spec's field list — no source ports, port ranges or per-interface defaults.
- One decision per packet, netfilter order: after NAT outside → inside and before NAT inside → outside, so rules always see inside (private) addresses (Linux FORWARD); a forwarded packet is matched by the first rule whose interface is its ingress (`in`) or egress (`out`); packets for the router are checked against their ingress's `in` rules (Linux INPUT); router-originated packets are never filtered (IOS outbound ACLs, Linux OUTPUT with no rules); TTL expiry is answered before filtering (Linux `ip_forward`) — one consistent place to read rules — IOS applies inbound ACLs before NAT and TTL.
- Stateful as iptables ESTABLISHED/RELATED: any packet let through records its flow (protocol, addresses, ports — echo identifier); later packets of that flow in either direction pass without rules, as do ICMP errors quoting it; flows idle out with the NAT timeouts; no TCP state machine — the spec says "risposte a connessioni stabilite ammesse" — a stray ACK of a known flow passes.
- A refused packet is dropped silently (iptables DROP, ASA) and logged as a drop event `firewall-rule` (a deny rule matched) or `firewall-default` (the default policy), at the interface of the deciding rule (ingress for the default) — the user asked for visible reasons — IOS would also send ICMP 3/13 ("!X" in traceroute).
- NAT and firewall run on routers only (spec §5.5); both saved per node (`nat`, `firewall`) like M3's services; copying or duplicating a router does not copy them (as DHCP/DNS) — consistency with M3 — none.
- No firewall flow table in the UI: spec §7.1 lists the NAT table only — added when a lab needs to show conntrack.

---

## File Structure

```
Sources/PacEngine/PDU.swift                  Endpoints, endpoints(_:), quotedEndpoints(_:), rewritten(_:src:srcPort:dst:dstPort:), withQuotedSource(_:_:_:)
Sources/PacEngine/L3/Nat.swift               (new) NAT_* timeouts, flowTimeout, NatEntry, Nat
Sources/PacEngine/L3/Firewall.swift          (new) Firewall (compiled rules, flow state)
Sources/PacEngine/L3/IpNode.swift            nat, firewall, the netfilter-order hooks in input/output, reset
Sources/PacEngine/Events.swift               DropReason.firewallRule, .firewallDefault
Sources/PacEngine/Runtime/Protocol.swift     NatConfig, Firewall* types, NatRow, setNat/setFirewall, NodeView and TopologyNode fields
Sources/PacEngine/Runtime/Runtime.swift      setNat/setFirewall, NAT rows, load
Sources/PacKit/Topology+Helpers.swift        NatRole, natRole, FirewallAction.label, ruleSummary, makeTopology nat/firewall
Sources/PacKit/Editor.swift                  setNatRole, addFirewallRule, removeFirewallRule
Sources/PacTrack/ServicesTab.swift           NAT roles, firewall toggle, default policy, rules
Sources/PacTrack/InspectorView.swift         Tabelle: Traduzioni NAT
Sources/PacTrack/SelfTest.swift              M5 scenario + two images
Tests/PacEngineTests/{NatTests,FirewallTests,RuntimeNatFirewallTests}.swift (new)
Tests/PacKitTests/NatFirewallEditorTests.swift (new)
docs/manual-checks/m5.md
```

---

### Task 1: Engine — NAT/PAT: packet rewriting, translation table, ICMP errors translated back

**Files:**
- Modify: `Sources/PacEngine/PDU.swift`, `Sources/PacEngine/L3/IpNode.swift`, `Sources/PacEngine/Runtime/Protocol.swift` (only the new `NatConfig`)
- Create: `Sources/PacEngine/L3/Nat.swift`, `Tests/PacEngineTests/NatTests.swift`

**Interfaces:**
- Consumes: `makeIpv4`, `makeTcp`, `makeIcmp`, `serializeHeader`, `serializeL4`, `internetChecksum`, `Node.iface(_:)` (throws `"<id> has no interface <name>"`), `IpNode.bindUdp/sendUdp/onIcmp`, `Ping`, `Traceroute`, `TcpFlow`, `IpNode.configureSink`.
- Produces: `struct Endpoints: Equatable { proto: UInt8; src: UInt32; srcPort: UInt16; dst: UInt32; dstPort: UInt16; reversed }`; `endpoints(_: Ipv4Packet) -> Endpoints?`; `quotedEndpoints(_: IcmpMessage) -> Endpoints?`; `rewritten(_:src:srcPort:dst:dstPort:) -> Ipv4Packet`; `withQuotedSource(_:_:_:) -> IcmpMessage`; `NAT_TCP_TIMEOUT`, `NAT_UDP_TIMEOUT`, `NAT_ICMP_TIMEOUT`, `NAT_FINRST_TIMEOUT`; `flowTimeout(_ proto: UInt8, closing: Bool = false) -> Int`; `struct NatEntry { proto, local, localPort, global, globalPort, remote, remotePort, expiresAt, closing }`; `final class Nat { config: NatConfig; init(node:config:) throws; view() -> [NatEntry]; reset(); outbound(_:from:to:) -> Ipv4Packet; inbound(_:on:) -> Ipv4Packet? }`; `IpNode.nat: Nat?`; `IpNode.output(_:from:)` (private, `from` = ingress of a forwarded packet); public `struct NatConfig: Codable, Equatable, Sendable { inside: [String]; outside: String?; init(inside: [String] = [], outside: String? = nil) }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/NatTests.swift`:

```swift
import Testing
@testable import PacEngine

/// H1 (192.168.1.10/24) and H2 (192.168.2.10/24) inside R1 (Gi0/0 192.168.1.1 and Gi0/2 192.168.2.1: inside; Gi0/1 203.0.113.1/24:
/// outside); SRV (203.0.113.10/24) outside, with no route back to the private networks.
private func natLab() throws -> (sim: Sim, h1: Host, h2: Host, r1: Router, srv: Host) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let srv = Host(sim: sim, id: "SRV")
    let r1 = Router(sim: sim, id: "R1", ports: 3)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try srv.iface("eth0"))
    _ = try Link(sim: sim, try h2.iface("eth0"), try r1.iface("Gi0/2"))
    try r1.setIp("Gi0/0", "192.168.1.1/24")
    try r1.setIp("Gi0/1", "203.0.113.1/24")
    try r1.setIp("Gi0/2", "192.168.2.1/24")
    try h1.setIp("eth0", "192.168.1.10/24")
    try h1.setGateway("192.168.1.1")
    try h2.setIp("eth0", "192.168.2.10/24")
    try h2.setGateway("192.168.2.1")
    try srv.setIp("eth0", "203.0.113.10/24")
    r1.nat = try Nat(node: r1, config: NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/1"))
    return (sim, h1, h2, r1, srv)
}

private struct Got: Equatable {
    let from: String
    let port: UInt16
    let checksumOk: Bool
}

private final class UdpLog {
    var got: [Got] = []
}

/// Records what reaches a UDP port (source, source port, IPv4 header checksum valid); `echo` answers each datagram.
private func listen(_ node: IpNode, _ port: UInt16, echo: Bool = false) throws -> UdpLog {
    let log = UdpLog()
    try node.bindUdp(port) { p, u, _ in
        log.got.append(Got(from: formatIp(p.src), port: u.srcPort, checksumOk: internetChecksum(serializeHeader(p)) == 0))
        if echo { node.sendUdp(p.src, srcPort: port, dstPort: u.srcPort, data: [1]) }
    }
    return log
}

/// ICMP errors a host received: the quoted bytes, and whether every outer IPv4 checksum held.
private final class Errors {
    var quotes: [[UInt8]] = []
    var headersOk = true
}

@Suite struct NatTests {
    @Test func rewritingRecomputesTheChecksumsAndAnErrorQuoteGetsItsSourceBack() throws {
        let (a, b, g) = (try parseIp("192.168.1.10"), try parseIp("203.0.113.10"), try parseIp("203.0.113.1"))
        let syn = makeTcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1000, ack: 0, flags: [.syn], window: 65535, mss: 1460), src: a, dst: b)
        let q = rewritten(makeIpv4(src: a, dst: b, ttl: 64, id: 1, payload: .tcp(syn)), src: g, srcPort: 1024)
        guard case .tcp(let t) = q.payload else {
            Issue.record("not TCP")
            return
        }
        #expect(q.src == g && q.dst == b && t.srcPort == 1024 && t.dstPort == 9)
        #expect(internetChecksum(serializeHeader(q)) == 0)
        #expect(t.checksum == makeTcp(t, src: g, dst: b).checksum && t.checksum != syn.checksum) // the pseudo-header changed
        let echo = makeIpv4(src: a, dst: b, ttl: 64, id: 2, payload: echoRequest())
        guard case .icmp(let m) = rewritten(echo, srcPort: 77).payload else {
            Issue.record("not ICMP")
            return
        }
        #expect(m.id == 77 && internetChecksum(serialize(m)) == 0)
        #expect(endpoints(echo) == Endpoints(proto: IPPROTO_ICMP, src: a, srcPort: 9, dst: b, dstPort: 0))
        // A router beyond the NAT quotes the translated echo; the NAT gives the quote back its inside source.
        let translated = rewritten(echo, src: g, srcPort: 77)
        let error = makeIcmp(type: ICMP_TIME_EXCEEDED, code: 0, id: 0, seq: 0, data: serializeHeader(translated) + serializeL4(translated).prefix(8))
        #expect(quotedEndpoints(error) == Endpoints(proto: IPPROTO_ICMP, src: g, srcPort: 77, dst: b, dstPort: 0))
        let back = withQuotedSource(error, a, 9)
        #expect(quotedEndpoints(back) == Endpoints(proto: IPPROTO_ICMP, src: a, srcPort: 9, dst: b, dstPort: 0))
        #expect(internetChecksum(Array(back.data[0..<20])) == 0) // quoted IPv4 header
        #expect(internetChecksum(Array(back.data[20..<28])) == 0) // quoted echo header (its 56 data bytes are zeros)
        #expect(internetChecksum(serialize(back)) == 0)
    }

    @Test func udpLeavesFromTheOutsideAddressKeepingItsPortAndTheReplyFindsItsWayBack() throws {
        let (sim, h1, _, r1, srv) = try natLab()
        let atSrv = try listen(srv, 7, echo: true)
        let atH1 = try listen(h1, 5000)
        h1.sendUdp(try parseIp("203.0.113.10"), srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        #expect(atSrv.got == [Got(from: "203.0.113.1", port: 5000, checksumOk: true)])
        #expect(atH1.got == [Got(from: "203.0.113.10", port: 7, checksumOk: true)])
        let table = try #require(r1.nat?.view())
        #expect(table.count == 1)
        let e = table[0]
        #expect(e.proto == IPPROTO_UDP && formatIp(e.local) == "192.168.1.10" && e.localPort == 5000)
        #expect(formatIp(e.global) == "203.0.113.1" && e.globalPort == 5000 && formatIp(e.remote) == "203.0.113.10" && e.remotePort == 7)
        #expect(e.expiresAt > sim.now + 299 * S) // 300 s from the reply
        sim.run(300 * S)
        #expect(r1.nat?.view().isEmpty == true)
    }

    @Test func twoHostsOnTheSamePortGetDifferentGlobalPortsAndOnlyTheContactedEndpointGetsBack() throws {
        let (sim, h1, h2, r1, srv) = try natLab()
        let at7 = try listen(srv, 7)
        let at8 = try listen(srv, 8)
        let atH1 = try listen(h1, 5000)
        let dst = try parseIp("203.0.113.10")
        h1.sendUdp(dst, srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        h2.sendUdp(dst, srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        h1.sendUdp(dst, srcPort: 5000, dstPort: 8, data: [0])
        sim.run(10 * MS)
        #expect(at7.got.map(\.port) == [5000, 5001]) // H2 found 5000 taken: the next free port
        #expect(at8.got.map(\.port) == [5000]) // H1 keeps its mapping for every remote (RFC 4787 REQ-1)
        #expect(r1.nat?.view().map { "\($0.localPort)→\($0.globalPort):\($0.remotePort)" } == ["5000→5000:7", "5000→5001:7", "5000→5000:8"])
        // Only the endpoint H1 contacted gets back in; the other datagram is the router's own and closed.
        let global = try parseIp("203.0.113.1")
        srv.sendUdp(global, srcPort: 9, dstPort: 5000, data: [0])
        srv.sendUdp(global, srcPort: 7, dstPort: 5000, data: [0])
        sim.run(10 * MS)
        #expect(atH1.got == [Got(from: "203.0.113.10", port: 7, checksumOk: true)])
        let unreachable = sim.log.all.filter {
            $0.kind == .tx && $0.node == "R1" && eventView($0).info == "203.0.113.1 → 203.0.113.10 Destination unreachable (port) ttl=255"
        }
        #expect(unreachable.count == 1)
    }

    @Test func pingAndTracerouteFromInsideWorkAndIcmpErrorsComeBackTranslated() throws {
        let (sim, h1, _, r1, _) = try natLab()
        let errors = Errors()
        h1.onIcmp { p, m in
            guard m.type == ICMP_DEST_UNREACH else { return }
            errors.quotes.append(m.data)
            errors.headersOk = errors.headersOk && internetChecksum(serializeHeader(p)) == 0
        }
        let ping = try Ping(node: h1, target: "203.0.113.10")
        sim.run(5 * S)
        #expect(ping.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        let echo = try #require(r1.nat?.view().first { $0.proto == IPPROTO_ICMP })
        #expect(echo.globalPort == echo.localPort && echo.remotePort == 0) // the echo identifier is kept
        let trace = try Traceroute(node: h1, target: "203.0.113.10")
        sim.run(5 * S)
        #expect(trace.result.done)
        #expect(trace.result.lines[1].hasPrefix(" 1  192.168.1.1 (192.168.1.1)"))
        #expect(trace.result.lines[2].hasPrefix(" 2  203.0.113.10 (203.0.113.10)"))
        // SRV's port unreachable quoted the translated probe; R1 put the inside source back and fixed the quoted checksum.
        let q = try #require(errors.quotes.first)
        #expect(errors.quotes.count == 3 && errors.headersOk)
        #expect(Array(q[12..<16]) == [192, 168, 1, 10] && internetChecksum(Array(q[0..<20])) == 0)
    }

    @Test func tcpCrossesWithRecomputedChecksumsAndItsTranslationEndsAMinuteAfterTheFin() throws {
        let (sim, h1, _, r1, srv) = try natLab()
        try srv.configureSink(true)
        let flow = try TcpFlow(node: h1, target: "203.0.113.10", bytes: 100_000)
        sim.run(1 * S)
        #expect(flow.result.lines.last == "iperf Done.")
        let atSrv = sim.log.all.filter { $0.kind == .rx && $0.node == "SRV" }.compactMap { e -> (Ipv4Packet, TcpSegment)? in
            guard case .ipv4(let p)? = e.frame?.payload, case .tcp(let t) = p.payload else { return nil }
            return (p, t)
        }
        #expect(!atSrv.isEmpty)
        #expect(atSrv.allSatisfy { formatIp($0.0.src) == "203.0.113.1" && makeTcp($0.1, src: $0.0.src, dst: $0.0.dst).checksum == $0.1.checksum })
        let tcp = try #require(r1.nat?.view().first { $0.proto == IPPROTO_TCP })
        #expect(tcp.closing && tcp.expiresAt <= sim.now + 60 * S)
        sim.run(60 * S)
        #expect(r1.nat?.view().isEmpty == true)
    }

    @Test func unsolicitedPacketsToTheOutsideAddressAreTheRoutersOwnAndAPowerCycleClearsTheTable() throws {
        let (sim, h1, _, r1, srv) = try natLab()
        let ping = try Ping(node: srv, target: "203.0.113.1")
        let refused = try TcpFlow(node: srv, target: "203.0.113.1", bytes: 1000)
        sim.run(4 * S)
        #expect(ping.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(refused.result.lines.last == "iperf3: error - unable to connect to server: Connection refused")
        #expect(r1.nat?.view().isEmpty == true)
        #expect(!sim.log.all.contains { $0.node == "H1" && $0.kind == .rx })
        h1.sendUdp(try parseIp("203.0.113.10"), srcPort: 5000, dstPort: 7, data: [0])
        sim.run(10 * MS)
        #expect(r1.nat?.view().count == 1)
        r1.reset()
        #expect(r1.nat?.view().isEmpty == true)
        #expect(r1.nat?.config == NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/1"))
    }

    @Test func rejectsUnknownInterfacesAndAnInterfaceBothInsideAndOutside() throws {
        let (_, _, _, r1, _) = try natLab()
        expectError("R1 has no interface Gi0/9") { _ = try Nat(node: r1, config: NatConfig(inside: ["Gi0/9"], outside: "Gi0/1")) }
        expectError("Gi0/1 cannot be both inside and outside") { _ = try Nat(node: r1, config: NatConfig(inside: ["Gi0/1"], outside: "Gi0/1")) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (outside the sandbox): `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `Nat`, `NatConfig`, `rewritten`, `Endpoints`, `quotedEndpoints`, `withQuotedSource` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Runtime/Protocol.swift` — after `struct DnsRecord { … }` add:

```swift
/// NAT/PAT roles of a router's interfaces (IOS `ip nat inside` / `ip nat outside`); inside traffic leaves with the outside address.
public struct NatConfig: Codable, Equatable, Sendable {
    public var inside: [String]
    public var outside: String?

    public init(inside: [String] = [], outside: String? = nil) {
        self.inside = inside
        self.outside = outside
    }
}
```

`Sources/PacEngine/PDU.swift` — at the end of the file add:

```swift
private func word16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
private func word32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(word16(b, i)) << 16 | UInt32(word16(b, i + 2)) }

/// A packet's flow as NAT and the firewall see it. ICMP echo uses its identifier as the requester's port (a request is
/// `id → 0`, its reply `0 → id`), so a reply is always the mirror image of its request.
struct Endpoints: Equatable {
    var proto: UInt8
    var src: UInt32
    var srcPort: UInt16
    var dst: UInt32
    var dstPort: UInt16

    var reversed: Endpoints { Endpoints(proto: proto, src: dst, srcPort: dstPort, dst: src, dstPort: srcPort) }
}

/// nil for ICMP other than echo: an error belongs to the flow it quotes (`quotedEndpoints`).
func endpoints(_ p: Ipv4Packet) -> Endpoints? {
    switch p.payload {
    case .tcp(let t): return Endpoints(proto: IPPROTO_TCP, src: p.src, srcPort: t.srcPort, dst: p.dst, dstPort: t.dstPort)
    case .udp(let u): return Endpoints(proto: IPPROTO_UDP, src: p.src, srcPort: u.srcPort, dst: p.dst, dstPort: u.dstPort)
    case .icmp(let m) where m.type == ICMP_ECHO_REQUEST:
        return Endpoints(proto: IPPROTO_ICMP, src: p.src, srcPort: m.id, dst: p.dst, dstPort: 0)
    case .icmp(let m) where m.type == ICMP_ECHO_REPLY:
        return Endpoints(proto: IPPROTO_ICMP, src: p.src, srcPort: 0, dst: p.dst, dstPort: m.id)
    case .icmp: return nil
    }
}

/// The flow an ICMP error is about, read from the IPv4 header and first 8 bytes it quotes (RFC 792), as its sender sent it.
func quotedEndpoints(_ m: IcmpMessage) -> Endpoints? {
    let q = m.data
    guard m.type == ICMP_DEST_UNREACH || m.type == ICMP_TIME_EXCEEDED, q.count >= 28 else { return nil }
    let (src, dst) = (word32(q, 12), word32(q, 16))
    switch q[9] {
    case IPPROTO_TCP, IPPROTO_UDP: return Endpoints(proto: q[9], src: src, srcPort: word16(q, 20), dst: dst, dstPort: word16(q, 22))
    case IPPROTO_ICMP where q[20] == ICMP_ECHO_REQUEST: return Endpoints(proto: IPPROTO_ICMP, src: src, srcPort: word16(q, 24), dst: dst, dstPort: 0)
    default: return nil
    }
}

/// `p` with new addresses and ports (ICMP echo: the identifier), every checksum recomputed as RFC 3022 §4.2 asks: the IPv4 header,
/// TCP's (its pseudo-header holds the addresses) and ICMP's; UDP's stays 0 (not computed, RFC 768).
func rewritten(_ p: Ipv4Packet, src: UInt32? = nil, srcPort: UInt16? = nil, dst: UInt32? = nil, dstPort: UInt16? = nil) -> Ipv4Packet {
    var q = p
    q.src = src ?? p.src
    q.dst = dst ?? p.dst
    switch p.payload {
    case .tcp(var t):
        t.srcPort = srcPort ?? t.srcPort
        t.dstPort = dstPort ?? t.dstPort
        q.payload = .tcp(makeTcp(t, src: q.src, dst: q.dst))
    case .udp(var u):
        u.srcPort = srcPort ?? u.srcPort
        u.dstPort = dstPort ?? u.dstPort
        q.payload = .udp(u)
    case .icmp(let m):
        let id = (m.type == ICMP_ECHO_REQUEST ? srcPort : m.type == ICMP_ECHO_REPLY ? dstPort : nil) ?? m.id
        q.payload = .icmp(makeIcmp(type: m.type, code: m.code, id: id, seq: m.seq, data: m.data))
    }
    return withChecksum(q)
}

/// RFC 1624 eqn. 3: a checksum after one 16-bit word of the data changed from `old` to `new`.
private func adjusted(_ checksum: UInt16, _ old: UInt16, _ new: UInt16) -> UInt16 {
    var sum = UInt32(~checksum) + UInt32(~old) + UInt32(new)
    while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum)
}

/// An ICMP error whose quoted packet gets a new source address and port (echo: identifier), as NAT hands it back inside
/// (RFC 5508 §4): the quoted IPv4 checksum is recomputed and a quoted echo's adjusted (RFC 1624); a quoted UDP checksum is 0
/// and TCP's lies beyond the 8 quoted bytes. `m` must quote a flow (`quotedEndpoints(m) != nil`).
func withQuotedSource(_ m: IcmpMessage, _ addr: UInt32, _ port: UInt16) -> IcmpMessage {
    var q = m.data
    let echo = q[9] == IPPROTO_ICMP
    let at = echo ? 24 : 20
    if echo { q.replaceSubrange(22..<24, with: u16(adjusted(word16(q, 22), word16(q, at), port))) }
    q.replaceSubrange(at..<at + 2, with: u16(port))
    q.replaceSubrange(12..<16, with: u32(addr))
    q.replaceSubrange(10..<12, with: [0, 0])
    q.replaceSubrange(10..<12, with: u16(internetChecksum(Array(q[0..<20]))))
    return makeIcmp(type: m.type, code: m.code, id: m.id, seq: m.seq, data: q)
}
```

Create `Sources/PacEngine/L3/Nat.swift`:

```swift
/// Idle timeouts (spec §5.4, IOS defaults): TCP 2 h 4 min (RFC 5382 REQ-5), UDP 5 min (RFC 4787 REQ-5), ICMP 60 s (RFC 5508's minimum).
let NAT_TCP_TIMEOUT = 7440 * S
let NAT_UDP_TIMEOUT = 300 * S
let NAT_ICMP_TIMEOUT = 60 * S
/// IOS `ip nat translation finrst-timeout`: a TCP translation lasts this long once a FIN or RST went by.
let NAT_FINRST_TIMEOUT = 60 * S

/// Idle timeout of a translation or a firewall flow.
func flowTimeout(_ proto: UInt8, closing: Bool = false) -> Int {
    switch proto {
    case IPPROTO_TCP: closing ? NAT_FINRST_TIMEOUT : NAT_TCP_TIMEOUT
    case IPPROTO_UDP: NAT_UDP_TIMEOUT
    default: NAT_ICMP_TIMEOUT
    }
}

/// One translation, an IOS "extended" entry: inside local ↔ inside global for one remote endpoint.
/// For ICMP echo the ports are the identifier and the remote port is 0.
struct NatEntry: Equatable {
    let proto: UInt8
    let local: UInt32
    let localPort: UInt16
    let global: UInt32
    let globalPort: UInt16
    let remote: UInt32
    let remotePort: UInt16
    var expiresAt: Int
    /// A FIN or RST went by.
    var closing = false
}

/// RFC 3022 NAPT on a router, IOS `ip nat inside source list … interface <outside> overload`: TCP, UDP and echo requests from an
/// inside interface routed out of the outside one take the outside address. Endpoint-independent mapping (RFC 4787 REQ-1),
/// address-and-port-dependent filtering (only an entry's remote endpoint gets back in). Unmatched packets to the outside
/// address are the router's own.
// ponytail: linear scans and lazy expiry (no timers); fine for lab-sized tables
final class Nat {
    unowned let node: IpNode
    let config: NatConfig
    private var entries: [NatEntry] = []

    init(node: IpNode, config: NatConfig) throws {
        for name in config.inside + [config.outside].compactMap({ $0 }) { _ = try node.iface(name) }
        if let outside = config.outside, config.inside.contains(outside) {
            throw EngineError("\(outside) cannot be both inside and outside")
        }
        self.node = node
        self.config = config
    }

    private var now: Int { node.sim.now }

    /// Live translations, oldest first.
    func view() -> [NatEntry] {
        entries.filter { $0.expiresAt > now }
    }

    /// Power cycle (`clear ip nat translation *`); the configuration stays.
    func reset() {
        entries = []
    }

    /// Inside → outside, after routing (RFC 3022 §2.2).
    func outbound(_ p: Ipv4Packet, from inIface: Interface, to outIface: Interface) -> Ipv4Packet {
        guard config.inside.contains(inIface.name), outIface.name == config.outside, let global = outIface.ipv4?.addr,
              let e = endpoints(p) else { return p }
        // ponytail: echo replies and ICMP errors from inside hosts leave untranslated (they only answer traffic routed in untranslated)
        if case .icmp(let m) = p.payload, m.type != ICMP_ECHO_REQUEST { return p }
        expire()
        let i = entries.firstIndex {
            $0.proto == e.proto && $0.local == e.src && $0.localPort == e.srcPort && $0.remote == e.dst && $0.remotePort == e.dstPort
        } ?? add(e, global: global)
        refresh(i, p)
        return rewritten(p, src: entries[i].global, srcPort: entries[i].globalPort)
    }

    /// Outside → inside, before routing: a reply to a translation, or an ICMP error about one (with its quoted packet,
    /// RFC 5508 §4), gets the inside address back. nil when nothing matches.
    func inbound(_ p: Ipv4Packet, on iface: Interface) -> Ipv4Packet? {
        guard iface.name == config.outside else { return nil }
        expire()
        if case .icmp(let m) = p.payload, let q = quotedEndpoints(m) {
            // The quote is our translated packet as it left (global → remote). An error never refreshes the entry.
            guard let e = entries.first(where: {
                $0.proto == q.proto && $0.global == q.src && $0.globalPort == q.srcPort && $0.remote == q.dst && $0.remotePort == q.dstPort
            }), p.dst == e.global else { return nil }
            var fixed = p
            fixed.payload = .icmp(withQuotedSource(m, e.local, e.localPort))
            return rewritten(fixed, dst: e.local)
        }
        guard let e = endpoints(p), let i = entries.firstIndex(where: {
            $0.proto == e.proto && $0.global == e.dst && $0.globalPort == e.dstPort && $0.remote == e.src && $0.remotePort == e.srcPort
        }) else { return nil }
        refresh(i, p)
        return rewritten(p, dst: entries[i].local, dstPort: entries[i].localPort)
    }

    /// RFC 4787 REQ-1: a mapped inside endpoint keeps its global port for every remote; a new one keeps its own port if free
    /// (IOS, Linux), else takes the next free one above it, wrapping to 1024.
    private func add(_ e: Endpoints, global: UInt32) -> Int {
        let same = { (n: NatEntry) in n.proto == e.proto && n.global == global }
        let mapped = entries.first { same($0) && $0.local == e.src && $0.localPort == e.srcPort }?.globalPort
        var port = mapped ?? e.srcPort
        if mapped == nil {
            // ponytail: 64 512 ports per protocol are never exhausted in a lab; no exhaustion handling
            while entries.contains(where: { same($0) && $0.globalPort == port }) { port = port == .max ? 1024 : port + 1 }
        }
        entries.append(NatEntry(proto: e.proto, local: e.src, localPort: e.srcPort, global: global, globalPort: port,
                                remote: e.dst, remotePort: e.dstPort, expiresAt: now))
        return entries.count - 1
    }

    private func refresh(_ i: Int, _ p: Ipv4Packet) {
        if case .tcp(let t) = p.payload, !t.flags.isDisjoint(with: [.fin, .rst]) { entries[i].closing = true }
        entries[i].expiresAt = now + flowTimeout(entries[i].proto, closing: entries[i].closing)
    }

    private func expire() {
        entries.removeAll { $0.expiresAt <= now }
    }
}
```

`Sources/PacEngine/L3/IpNode.swift`:

After `var dnsServer: DnsServer?` add:

```swift
    /// NAT/PAT (routers): translates between the inside interfaces and the outside one.
    var nat: Nat?
```

In `reset()`, after `tcp.reset()` add `nat?.reset()`.

Replace `input` and `output`:

```swift
    private func input(_ p: Ipv4Packet, on iface: Interface) {
        // NAT outside → inside comes before routing; inside → outside after it (`output`).
        let packet = nat?.inbound(p, on: iface) ?? p
        let subnetBroadcast = iface.ipv4.map { packet.dst == broadcastOf($0.addr, $0.prefix) } ?? false
        if ownsIp(packet.dst) || packet.dst == BROADCAST_IP || subnetBroadcast { return deliver(packet, from: iface) }
        guard forwarding else { return }
        if packet.ttl <= 1 {
            sim.emit(.drop, node: id, iface: iface.name, packet: packet, reason: .ttlExpired)
            return icmpError(packet, type: ICMP_TIME_EXCEEDED, code: 0)
        }
        output(withTtl(packet, packet.ttl - 1), from: iface)
    }

    /// Routes and sends a packet; `inIface` is where a forwarded one came in (nil: this node originated it).
    private func output(_ p: Ipv4Packet, from inIface: Interface? = nil) {
        if ownsIp(p.dst) {
            sim.sched.after(0) { [self] in deliver(p, from: nil) }
            return
        }
        guard let hop = routes.lookup(p.dst) else {
            sim.emit(.drop, node: id, packet: p, reason: .noRoute)
            return icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_NET)
        }
        let packet = inIface.flatMap { nat?.outbound(p, from: $0, to: hop.iface) } ?? p
        if packet.size > hop.iface.mtu {
            // ponytail: no IPv4 fragmentation; non-DF oversize packets are dropped
            sim.emit(.drop, node: id, iface: hop.iface.name, packet: packet, reason: .mtuExceeded)
            if packet.dontFragment { icmpError(packet, type: ICMP_DEST_UNREACH, code: UNREACH_FRAG_NEEDED) }
            return
        }
        arp.send(hop.iface, nextHop: hop.nextHop, packet)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: `✔ Test run with … tests … passed` (7 more than before this task; the routing, ping, traceroute and TCP suites still pass — nodes without NAT take the old path).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/PDU.swift Sources/PacEngine/L3/Nat.swift Sources/PacEngine/L3/IpNode.swift Sources/PacEngine/Runtime/Protocol.swift Tests/PacEngineTests/NatTests.swift
git commit -m "feat(engine): add NAT/PAT with a translation table, port preservation and ICMP errors translated back

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Engine — stateful firewall: ordered rules, first match, default policy, drop reasons

**Files:**
- Modify: `Sources/PacEngine/L3/IpNode.swift`, `Sources/PacEngine/Events.swift`, `Sources/PacEngine/Runtime/Protocol.swift` (only the new firewall types)
- Create: `Sources/PacEngine/L3/Firewall.swift`, `Tests/PacEngineTests/FirewallTests.swift`

**Interfaces:**
- Consumes: Task 1 (`Endpoints`, `endpoints(_:)`, `quotedEndpoints(_:)`, `flowTimeout(_:closing:)`, `IpNode.output(_:from:)`), `parseIp`, `parseCidr`, `inSubnet`, `Cidr`, `routedPair()` and `drops(_:_:)` from `TestUtils.swift`.
- Produces: public `enum FirewallAction: String { allow, deny }`, `enum FirewallDirection: String { inbound = "in", outbound = "out" }`, `enum FirewallProto: String { any, icmp, tcp, udp }` (all `Codable, CaseIterable, Sendable`); `struct FirewallRule { iface, direction, action, proto, src, dst: String; port: Int?; init(…, port: Int? = nil) }`; `struct FirewallConfig { rules: [FirewallRule]; defaultAction: FirewallAction; init(rules: [] , defaultAction: .allow) }`; `DropReason.firewallRule = "firewall-rule"`, `.firewallDefault = "firewall-default"`; `final class Firewall { config; init(node:config:) throws; reset(); admits(_:from:to:) -> Bool }`; `IpNode.firewall: Firewall?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/FirewallTests.swift`:

```swift
import Testing
@testable import PacEngine

private func rule(_ iface: String, _ direction: FirewallDirection, _ action: FirewallAction, _ proto: FirewallProto = .any,
                  _ src: String = "any", _ dst: String = "any", port: Int? = nil) -> FirewallRule {
    FirewallRule(iface: iface, direction: direction, action: action, proto: proto, src: src, dst: dst, port: port)
}

/// routedPair(): H1 10.0.1.10 — R1 (Gi0/0 10.0.1.1 | Gi0/1 10.0.2.1) — H2 10.0.2.10.
@Suite struct FirewallTests {
    @Test func theFirstMatchingRuleDecidesAndDenialsAreLoggedWithTheirReason() throws {
        let (sim, h1, _, r1) = try routedPair()
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [
            rule("Gi0/0", .inbound, .deny, .icmp, "any", "10.0.2.10"),
            rule("Gi0/0", .inbound, .allow, .icmp),
        ]))
        let denied = try Ping(node: h1, target: "10.0.2.10")
        sim.run(15 * S)
        let toRouter = try Ping(node: h1, target: "10.0.2.1") // for R1 itself: rule 1 does not match, rule 2 does
        sim.run(5 * S)
        #expect(denied.result.lines.contains("4 packets transmitted, 0 received, 100% packet loss"))
        #expect(toRouter.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        let drop = try #require(sim.log.all.first { $0.reason == .firewallRule })
        #expect(drop.node == "R1" && drop.iface == "Gi0/0" && eventView(drop).info.hasPrefix("10.0.1.10 → 10.0.2.10 Echo request"))
        #expect(eventView(drop).reason == "firewall-rule")
        #expect(drops(sim, .firewallRule) == 4 && drops(sim, .firewallDefault) == 0)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [
            rule("Gi0/0", .inbound, .allow, .icmp),
            rule("Gi0/0", .inbound, .deny, .icmp, "any", "10.0.2.10"),
        ]))
        let swapped = try Ping(node: h1, target: "10.0.2.10")
        sim.run(5 * S)
        #expect(swapped.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
    }

    @Test func withADefaultDenyOnlyRepliesAndErrorsAboutAllowedFlowsGetBack() throws {
        let (sim, h1, h2, r1) = try routedPair()
        try h2.configureSink(true)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [rule("Gi0/0", .inbound, .allow)], defaultAction: .deny))
        let out = try Ping(node: h1, target: "10.0.2.10")
        sim.run(5 * S)
        let flow = try TcpFlow(node: h1, target: "10.0.2.10", bytes: 100_000)
        sim.run(1 * S)
        let trace = try Traceroute(node: h1, target: "10.0.2.10")
        sim.run(1 * S)
        let back = try Ping(node: h2, target: "10.0.1.10")
        let toRouter = try Ping(node: h2, target: "10.0.2.1")
        sim.run(15 * S)
        #expect(out.result.lines.contains("4 packets transmitted, 4 received, 0% packet loss"))
        #expect(flow.result.lines.last == "iperf Done.")
        #expect(trace.result.done && trace.result.lines[2].hasPrefix(" 2  10.0.2.10 (10.0.2.10)")) // H2's port unreachable is RELATED
        #expect(back.result.lines.contains("4 packets transmitted, 0 received, 100% packet loss"))
        #expect(toRouter.result.lines.contains("4 packets transmitted, 0 received, 100% packet loss")) // the default covers R1 itself
        #expect(drops(sim, .firewallDefault) == 8 && drops(sim, .firewallRule) == 0)
        #expect(sim.log.all.filter { $0.reason == .firewallDefault }.allSatisfy { $0.node == "R1" && $0.iface == "Gi0/1" })
    }

    @Test func portRulesMatchTheDestinationPortAndOutboundRulesFilterOnTheWayOut() throws {
        let (sim, h1, h2, r1) = try routedPair()
        try h2.configureSink(true)
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [
            rule("Gi0/0", .inbound, .deny, .tcp, "10.0.1.0/24", "10.0.2.10", port: 9),
            rule("Gi0/1", .outbound, .deny, .udp, port: 9),
        ]))
        let tcp = try TcpFlow(node: h1, target: "10.0.2.10", bytes: 1000)
        _ = try UdpFlow(node: h1, target: "10.0.2.10", bitsPerSecond: 1e6, seconds: 1)
        sim.run(2 * S)
        let atIn = sim.log.all.filter { $0.reason == .firewallRule && $0.iface == "Gi0/0" }
        #expect(atIn.count == 2 && atIn.allSatisfy { eventView($0).info.contains("[SYN]") }) // the SYN and its retransmission at 1 s
        #expect(sim.log.all.filter { $0.reason == .firewallRule && $0.iface == "Gi0/1" }.count == 86) // every datagram to port 9
        #expect(h2.tcp.connections.isEmpty && !tcp.result.done)
        h1.sendUdp(try parseIp("10.0.2.10"), srcPort: 5000, dstPort: 7, data: [0]) // another port: allowed by default
        sim.run(10 * MS)
        #expect(sim.log.all.contains { $0.kind == .tx && $0.node == "H2" && eventView($0).info.contains("Destination unreachable (port)") })
    }

    @Test func rejectsRulesThatCannotMatch() throws {
        let (_, _, _, r1) = try routedPair()
        let make = { (r: FirewallRule) in _ = try Firewall(node: r1, config: FirewallConfig(rules: [r])) }
        expectError("R1 has no interface Gi0/7") { try make(rule("Gi0/7", .inbound, .deny)) }
        expectError("Invalid IPv4 address: \"10.0.0\"") { try make(rule("Gi0/0", .inbound, .deny, .any, "10.0.0")) }
        expectError("Invalid CIDR: \"10.0.0.0/33\"") { try make(rule("Gi0/0", .inbound, .deny, .any, "any", "10.0.0.0/33")) }
        expectError("A port needs TCP or UDP") { try make(rule("Gi0/0", .inbound, .deny, .icmp, port: 80)) }
        expectError("Port must be between 1 and 65535") { try make(rule("Gi0/0", .inbound, .deny, .tcp, port: 0)) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `Firewall`, `FirewallRule`, `FirewallConfig`, `.firewallRule` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Events.swift` — in `DropReason`, after `case mtuExceeded = "mtu-exceeded"` add:

```swift
    /// A firewall deny rule matched.
    case firewallRule = "firewall-rule"
    /// No firewall rule matched and the default policy denies.
    case firewallDefault = "firewall-default"
```

`Sources/PacEngine/Runtime/Protocol.swift` — after `struct NatConfig { … }` add:

```swift
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
```

Create `Sources/PacEngine/L3/Firewall.swift`:

```swift
import Foundation

/// A rule as matched: "any" is 0.0.0.0/0, an address /32.
private struct CompiledRule {
    let iface: String
    let out: Bool
    let allow: Bool
    let proto: UInt8?
    let src: Cidr
    let dst: Cidr
    let port: UInt16?

    func matches(_ p: Ipv4Packet, _ e: Endpoints?) -> Bool {
        (proto.map { $0 == p.proto } ?? true) && inSubnet(p.src, src.addr, src.prefix) && inSubnet(p.dst, dst.addr, dst.prefix)
            && (port.map { $0 == e?.dstPort } ?? true)
    }
}

private func parseMatch(_ text: String) throws -> Cidr {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.lowercased() == "any" { return Cidr(addr: 0, prefix: 0) }
    return t.contains("/") ? try parseCidr(t) : Cidr(addr: try parseIp(t), prefix: 32)
}

private func compile(_ r: FirewallRule, on node: IpNode) throws -> CompiledRule {
    _ = try node.iface(r.iface)
    if let port = r.port {
        guard r.proto == .tcp || r.proto == .udp else { throw EngineError("A port needs TCP or UDP") }
        guard (1...65535).contains(port) else { throw EngineError("Port must be between 1 and 65535") }
    }
    let proto: UInt8? = switch r.proto {
    case .any: nil
    case .icmp: IPPROTO_ICMP
    case .tcp: IPPROTO_TCP
    case .udp: IPPROTO_UDP
    }
    return CompiledRule(iface: r.iface, out: r.direction == .outbound, allow: r.action == .allow, proto: proto,
                        src: try parseMatch(r.src), dst: try parseMatch(r.dst), port: r.port.map { UInt16($0) })
}

/// Stateful packet filter on a router (spec §5.4), one decision per packet in netfilter order: after NAT outside → inside, before
/// NAT inside → outside, so rules see inside addresses. A packet let through records its flow; the flow's later packets in either
/// direction, and ICMP errors quoting it, pass without rules (iptables ESTABLISHED/RELATED). Otherwise the first rule whose
/// interface is the packet's ingress (`in`) or egress (`out`) decides, then the default policy. Router-originated packets are never checked.
// ponytail: flows idle out like NAT translations (no TCP state machine); linear scans
final class Firewall {
    unowned let node: IpNode
    let config: FirewallConfig
    private let rules: [CompiledRule]
    /// Flows let through, as their first packet went, with their idle deadline.
    private var flows: [(flow: Endpoints, expiresAt: Int)] = []

    init(node: IpNode, config: FirewallConfig) throws {
        rules = try config.rules.map { try compile($0, on: node) }
        self.node = node
        self.config = config
    }

    /// Power cycle: tracked flows are forgotten; the rules stay.
    func reset() {
        flows = []
    }

    /// A packet forwarded from `inIface` to `outIface`, or for the router itself (`outIface` nil). A refused one is logged as a drop.
    func admits(_ p: Ipv4Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
        let now = node.sim.now
        flows.removeAll { $0.expiresAt <= now }
        let e = endpoints(p)
        if let e, let i = flows.firstIndex(where: { $0.flow == e || $0.flow == e.reversed }) {
            flows[i].expiresAt = now + flowTimeout(e.proto)
            return true
        }
        if case .icmp(let m) = p.payload, let q = quotedEndpoints(m), flows.contains(where: { $0.flow == q || $0.flow == q.reversed }) {
            return true
        }
        let rule = rules.first { $0.matches(p, e) && $0.iface == ($0.out ? outIface?.name : inIface.name) }
        guard rule?.allow ?? (config.defaultAction == .allow) else {
            let at = rule?.out == true ? outIface ?? inIface : inIface
            node.sim.emit(.drop, node: node.id, iface: at.name, packet: p, reason: rule == nil ? .firewallDefault : .firewallRule)
            return false
        }
        if let e { flows.append((e, now + flowTimeout(e.proto))) }
        return true
    }
}
```

`Sources/PacEngine/L3/IpNode.swift`:

After `var nat: Nat?` add:

```swift
    /// Stateful firewall (routers).
    var firewall: Firewall?
```

In `reset()`, after `nat?.reset()` add `firewall?.reset()`.

Replace `input` (only the comment and the delivery branch change):

```swift
    private func input(_ p: Ipv4Packet, on iface: Interface) {
        // Netfilter order: NAT outside → inside, then routing and filtering (here for the router itself, in `output` for forwarded
        // packets), then NAT inside → outside.
        let packet = nat?.inbound(p, on: iface) ?? p
        let subnetBroadcast = iface.ipv4.map { packet.dst == broadcastOf($0.addr, $0.prefix) } ?? false
        if ownsIp(packet.dst) || packet.dst == BROADCAST_IP || subnetBroadcast {
            guard firewall?.admits(packet, from: iface, to: nil) ?? true else { return }
            return deliver(packet, from: iface)
        }
        guard forwarding else { return }
        if packet.ttl <= 1 {
            sim.emit(.drop, node: id, iface: iface.name, packet: packet, reason: .ttlExpired)
            return icmpError(packet, type: ICMP_TIME_EXCEEDED, code: 0)
        }
        output(withTtl(packet, packet.ttl - 1), from: iface)
    }
```

In `output`, before `let packet = inIface.flatMap { … }` add:

```swift
        if let inIface, let firewall, !firewall.admits(p, from: inIface, to: hop.iface) { return }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (4 more than before this task; NatTests unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/L3/Firewall.swift Sources/PacEngine/L3/IpNode.swift Sources/PacEngine/Events.swift Sources/PacEngine/Runtime/Protocol.swift Tests/PacEngineTests/FirewallTests.swift
git commit -m "feat(engine): add a stateful firewall with ordered rules, a default policy and drop reasons

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Runtime — setNat/setFirewall, NAT table and configurations in the snapshot, persistence

**Files:**
- Modify: `Sources/PacEngine/Runtime/Protocol.swift`, `Sources/PacEngine/Runtime/Runtime.swift` (only `handle`, `build`, `load` and one new helper)
- Create: `Tests/PacEngineTests/RuntimeNatFirewallTests.swift`

**Interfaces:**
- Consumes: Task 1 (`Nat`, `NatEntry`, `NatConfig`, `Nat.view()`), Task 2 (`Firewall`, `FirewallConfig`, `FirewallRule`), existing `ipNode(_:)`, `secondsLeft(_:)`, `formatIp`.
- Produces (public): `Command.setNat(node:config:)`, `.setFirewall(node:config:)` (keys = case names); `struct NatRow { proto, insideLocal, insideGlobal, outside: String; ttlS: Int }`; `NodeView.nat: NatConfig?`, `.natTable: [NatRow]`, `.firewall: FirewallConfig?`; `TopologyNode.nat`, `.firewall` (init defaults nil, optional on read).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacEngineTests/RuntimeNatFirewallTests.swift`:

```swift
import Foundation
import Testing
@testable import PacEngine

private let NAT = NatConfig(inside: ["Gi0/0"], outside: "Gi0/1")
private let FIREWALL = FirewallConfig(rules: [FirewallRule(iface: "Gi0/0", direction: .inbound, action: .allow, proto: .any, src: "any", dst: "any")],
                                      defaultAction: .deny)

/// PC1 (192.168.1.10/24, gateway .1) — R1 (Gi0/0 192.168.1.1/24 inside, Gi0/1 203.0.113.1/24 outside; firewall: deny by default,
/// anything entering Gi0/0 allowed) — SRV1 (203.0.113.10/24, sink on, no gateway).
private func natRuntime() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
    try rt.handle(.addNode(id: "srv", kind: .server, name: "SRV1"))
    try rt.handle(.connect(id: "l1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0")))
    try rt.handle(.connect(id: "l2", a: IfaceRef(node: "r", iface: "Gi0/1"), b: IfaceRef(node: "srv", iface: "eth0")))
    for (node, iface, cidr) in [("a", "eth0", "192.168.1.10/24"), ("r", "Gi0/0", "192.168.1.1/24"), ("r", "Gi0/1", "203.0.113.1/24"),
                                ("srv", "eth0", "203.0.113.10/24")] {
        try rt.handle(.setIp(node: node, iface: iface, cidr: cidr))
    }
    try rt.handle(.addRoute(node: "a", cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
    try rt.handle(.setNat(node: "r", config: NAT))
    try rt.handle(.setFirewall(node: "r", config: FIREWALL))
    try rt.handle(.setSink(node: "srv", on: true))
    return rt
}

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct RuntimeNatFirewallTests {
    @Test func showsTranslationsAndDropsAndForgetsTranslationsOnAPowerCycle() throws {
        let rt = try natRuntime()
        try rt.handle(.trafficTcp(node: "a", target: "203.0.113.10", bytes: 100_000))
        try rt.handle(.ping(node: "srv", target: "203.0.113.1"))
        runFor(rt, wallMs: 1_000)
        let s = rt.snapshot()
        let r = s.nodes[1]
        #expect(s.apps[0].lines.last == "iperf Done.") // NAT and a default-deny firewall on the same router
        #expect(r.nat == NAT && r.firewall == FIREWALL)
        #expect(s.nodes[0].nat == nil && s.nodes[0].firewall == nil && s.nodes[0].natTable.isEmpty)
        let row = try #require(r.natTable.first)
        let port = row.insideLocal.split(separator: ":")[1]
        #expect(r.natTable.count == 1 && row.proto == "tcp" && row.insideLocal == "192.168.1.10:\(port)")
        #expect(row.insideGlobal == "203.0.113.1:\(port)" && row.outside == "203.0.113.10:9")
        #expect((59...60).contains(row.ttlS)) // closed: a minute after its FIN
        #expect(rt.events(from: 0).contains { $0.kind == .drop && $0.node == "r" && $0.iface == "Gi0/1" && $0.reason == "firewall-default" })
        #expect(!s.apps[1].lines.contains { $0.contains("bytes from") }) // SRV1 may not ping R1
        try rt.handle(.setPower(id: "r", on: false))
        #expect(rt.snapshot().nodes[1].natTable.isEmpty && rt.snapshot().nodes[1].nat == NAT)
    }

    @Test func onlyRoutersRunNatAndAFirewallAndARefusedChangeKeepsTheOldOne() throws {
        let rt = try natRuntime()
        expectError("PC1 cannot run NAT") { try rt.handle(.setNat(node: "a", config: NAT)) }
        expectError("SRV1 cannot run a firewall") { try rt.handle(.setFirewall(node: "srv", config: FirewallConfig())) }
        expectError("Gi0/1 cannot be both inside and outside") {
            try rt.handle(.setNat(node: "r", config: NatConfig(inside: ["Gi0/1"], outside: "Gi0/1")))
        }
        expectError("A port needs TCP or UDP") {
            try rt.handle(.setFirewall(node: "r", config: FirewallConfig(rules: [
                FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .icmp, src: "any", dst: "any", port: 7),
            ])))
        }
        #expect(rt.snapshot().nodes[1].nat == NAT && rt.snapshot().nodes[1].firewall == FIREWALL)
        try rt.handle(.setNat(node: "r", config: nil))
        try rt.handle(.setFirewall(node: "r", config: nil))
        #expect(rt.snapshot().nodes[1].nat == nil && rt.snapshot().nodes[1].firewall == nil)
    }

    @Test func loadsNatAndFirewallAndOpensOlderFilesWithoutThem() throws {
        let t = Topology(seed: 3, nodes: [
            TopologyNode(id: "r", kind: .router, name: "R1", pos: Pos(x: 0, y: 0), ifaces: [TopologyIface(name: "Gi0/0", cidr: "192.168.1.1/24")],
                         routes: [], nat: NAT, firewall: FIREWALL),
        ])
        let rt = Runtime()
        try rt.handle(.load(t))
        #expect(rt.snapshot().nodes[0].nat == NAT && rt.snapshot().nodes[0].firewall == FIREWALL)
        let old = #"{"id":"r","kind":"router","name":"R1","pos":{"x":0,"y":0},"ifaces":[],"routes":[]}"#
        let node = try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8))
        #expect(node.nat == nil && node.firewall == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `.setNat`, `.setFirewall`, `natTable`, `TopologyNode(…nat:firewall:)` unknown.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Runtime/Protocol.swift`:

In `enum Command`, after `case trafficUdp(…)` add:

```swift
    /// NAT/PAT interface roles (routers only); nil turns NAT off. Any change forgets the translations.
    case setNat(node: String, config: NatConfig?)
    /// Firewall rules and default policy (routers only); nil turns it off. Any change forgets the tracked flows.
    case setFirewall(node: String, config: FirewallConfig?)
```

and in `key`, after `case .trafficUdp: "trafficUdp"`:

```swift
        case .setNat: "setNat"
        case .setFirewall: "setFirewall"
```

After `struct TcpRow { … }` add:

```swift
/// One row of a router's NAT table, `show ip nat translations` style (ICMP: the echo identifier as port).
public struct NatRow: Equatable, Sendable {
    public let proto: String
    public let insideLocal: String
    public let insideGlobal: String
    public let outside: String
    /// Seconds until the translation idles out.
    public let ttlS: Int
}
```

In `NodeView`, after `public let tcp: [TcpRow]` add:

```swift
    /// NAT interface roles; nil while NAT is off.
    public let nat: NatConfig?
    /// Live translations, oldest first.
    public let natTable: [NatRow]
    /// nil while the firewall is off.
    public let firewall: FirewallConfig?
```

`TopologyNode`: add `public var nat: NatConfig?` and `public var firewall: FirewallConfig?` after `public var sink: Bool`; the memberwise `init` gains two last parameters `nat: NatConfig? = nil, firewall: FirewallConfig? = nil` (`self.nat = nat`, `self.firewall = firewall`); the decoder gains

```swift
        nat = try c.decodeIfPresent(NatConfig.self, forKey: .nat)
        firewall = try c.decodeIfPresent(FirewallConfig.self, forKey: .firewall)
```

and its doc comment becomes `/// Files written before M2b have no \`powered\`, before M3 no services, before M4 no \`sink\`, before M5 no \`nat\`/\`firewall\`.`

`Sources/PacEngine/Runtime/Runtime.swift`:

In `handle`, after the `.trafficUdp` case add:

```swift
        case let .setNat(node, config):
            let n = try ipNode(node)
            guard config == nil || nodes[node]?.kind == .router else { throw EngineError("\(n.name) cannot run NAT") }
            n.nat = try config.map { try Nat(node: n, config: $0) }
        case let .setFirewall(node, config):
            let n = try ipNode(node)
            guard config == nil || nodes[node]?.kind == .router else { throw EngineError("\(n.name) cannot run a firewall") }
            n.firewall = try config.map { try Firewall(node: n, config: $0) }
```

After `private func tcpRows(_:)` add:

```swift
    /// show ip nat translations: protocol, inside local, inside global, outside, seconds left; oldest first.
    private func natRows(_ nat: Nat, _ now: Int) -> [NatRow] {
        nat.view().map { e in
            NatRow(proto: e.proto == IPPROTO_TCP ? "tcp" : e.proto == IPPROTO_UDP ? "udp" : "icmp",
                   insideLocal: "\(formatIp(e.local)):\(e.localPort)", insideGlobal: "\(formatIp(e.global)):\(e.globalPort)",
                   outside: "\(formatIp(e.remote)):\(e.remotePort)", ttlS: secondsLeft(e.expiresAt - now))
        }
    }
```

In `build()`, the `NodeView(…)` call's last argument `tcp: ip.map { tcpRows($0) } ?? []` becomes:

```swift
                tcp: ip.map { tcpRows($0) } ?? [],
                nat: ip?.nat?.config,
                natTable: (ip?.nat).map { natRows($0, now) } ?? [],
                firewall: ip?.firewall?.config
```

In `load(_:)`, in the services loop after `if n.sink { … }` add:

```swift
            if let nat = n.nat { try next.handle(.setNat(node: n.id, config: nat)) }
            if let firewall = n.firewall { try next.handle(.setFirewall(node: n.id, config: firewall)) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (3 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Runtime/Protocol.swift Sources/PacEngine/Runtime/Runtime.swift Tests/PacEngineTests/RuntimeNatFirewallTests.swift
git commit -m "feat(engine): expose NAT and firewall commands, the NAT table and both configurations, save them per router

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: PacKit — NAT roles, firewall rules from typed fields, rule text, saving both

**Files:**
- Modify: `Sources/PacKit/Topology+Helpers.swift`, `Sources/PacKit/Editor.swift`
- Create: `Tests/PacKitTests/NatFirewallEditorTests.swift`

**Interfaces:**
- Consumes: Task 3 (`.setNat`, `.setFirewall`, `NodeView.nat/.firewall`, `TopologyNode(…nat:firewall:)`), Task 2 (`FirewallRule`, `FirewallConfig`, `FirewallAction`), existing `Editor.serialized/editNow`, `EditorError`.
- Produces: `public enum NatRole: String, CaseIterable { off = "—", inside, outside }`; `public func natRole(_: NatConfig?, _ iface: String) -> NatRole`; `FirewallAction.label` ("consenti"/"nega"); `public func ruleSummary(_: FirewallRule) -> String`; `Editor.setNatRole(_:iface:_:) async` (errors under `"nat:<node>"`); `Editor.addFirewallRule(_:_:port:) async -> Bool` (`@discardableResult`, errors under `"fw:<node>"`); `Editor.removeFirewallRule(_:at:) async`; `makeTopology` saves `nat` and `firewall`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PacKitTests/NatFirewallEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct NatFirewallEditorTests {
    let editor = Editor(client: Simulation())

    private var r1: NodeView { editor.snapshot.nodes[0] }

    private func router() async -> String {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        return r1.id
    }

    @Test func natRolesAllowOneOutsideAndNoRolesTurnNatOff() async {
        let r = await router()
        await editor.setNatRole(r, iface: "Gi0/2", .inside)
        await editor.setNatRole(r, iface: "Gi0/0", .inside)
        await editor.setNatRole(r, iface: "Gi0/1", .outside)
        #expect(r1.nat == NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/1")) // interface order
        await editor.setNatRole(r, iface: "Gi0/3", .outside)
        #expect(r1.nat == NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/3")) // the old outside loses its role
        #expect(natRole(r1.nat, "Gi0/1") == .off && natRole(r1.nat, "Gi0/3") == .outside && natRole(r1.nat, "Gi0/0") == .inside)
        await editor.undo()
        #expect(r1.nat?.outside == "Gi0/1")
        for name in ["Gi0/0", "Gi0/1", "Gi0/2"] { await editor.setNatRole(r, iface: name, .off) }
        #expect(r1.nat == nil && editor.current.nodes[0].nat == nil)
    }

    @Test func firewallRulesComeFromTypedFieldsAreRemovedAndSaved() async {
        let r = await router()
        let key = "fw:\(r)"
        await editor.edit(.setFirewall(node: r, config: FirewallConfig()))
        let deny = FirewallRule(iface: "Gi0/1", direction: .inbound, action: .deny, proto: .tcp, src: " ", dst: "203.0.113.1")
        var ok = await editor.addFirewallRule(r, deny, port: "ottanta")
        #expect(!ok && editor.error == EditorError(key: key, message: "Invalid number: \"ottanta\""))
        ok = await editor.addFirewallRule(r, FirewallRule(iface: "Gi0/1", direction: .inbound, action: .deny, proto: .icmp, src: "", dst: ""), port: "80")
        #expect(!ok && editor.error == EditorError(key: key, message: "A port needs TCP or UDP"))
        ok = await editor.addFirewallRule(r, deny, port: " 80 ")
        #expect(ok)
        await editor.addFirewallRule(r, FirewallRule(iface: "Gi0/0", direction: .outbound, action: .allow, proto: .any, src: "10.0.0.0/8", dst: ""),
                                     port: "")
        #expect(editor.error == nil)
        #expect(r1.firewall?.rules.map(ruleSummary) == ["in Gi0/1 · nega tcp any → 203.0.113.1 porta 80", "out Gi0/0 · consenti any 10.0.0.0/8 → any"])
        #expect(editor.current.nodes[0].firewall == r1.firewall)
        await editor.removeFirewallRule(r, at: 0)
        #expect(r1.firewall?.rules.count == 1)
        await editor.undo()
        #expect(r1.firewall?.rules.count == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh 2>&1 | tail -30`
Expected: build errors — `setNatRole`, `NatRole`, `natRole`, `addFirewallRule`, `ruleSummary` unknown.

- [ ] **Step 3: Implement**

`Sources/PacKit/Topology+Helpers.swift`:

After `enum TrafficKind { … }` add:

```swift
/// A router interface's NAT role (Servizi tab): IOS `ip nat inside` / `ip nat outside`.
public enum NatRole: String, CaseIterable, Sendable {
    case off = "—", inside, outside
}

public func natRole(_ config: NatConfig?, _ iface: String) -> NatRole {
    if config?.outside == iface { return .outside }
    return config?.inside.contains(iface) == true ? .inside : .off
}

extension FirewallAction {
    public var label: String {
        switch self {
        case .allow: "consenti"
        case .deny: "nega"
        }
    }
}

/// One rule as listed: "in Gi0/1 · nega tcp any → 203.0.113.1 porta 80".
public func ruleSummary(_ r: FirewallRule) -> String {
    "\(r.direction.rawValue) \(r.iface) · \(r.action.label) \(r.proto.rawValue) \(r.src) → \(r.dst)" + (r.port.map { " porta \($0)" } ?? "")
}
```

In `makeTopology`, the `TopologyNode(…)` call ends `dns: n.dnsRecords, sink: n.sink, nat: n.nat, firewall: n.firewall)`.

`Sources/PacKit/Editor.swift` — after `removeDnsRecord(_:at:)` add:

```swift
    /// Gives a router interface a NAT role; a new outside replaces the old one and no roles left turn NAT off. Errors show under NAT.
    public func setNatRole(_ id: String, iface: String, _ role: NatRole) async {
        await serialized {
            guard let node = self.snapshot.nodes.first(where: { $0.id == id }) else { return }
            var c = node.nat ?? NatConfig()
            c.inside.removeAll { $0 == iface }
            if c.outside == iface { c.outside = nil }
            switch role {
            case .off: break
            case .inside:
                let kept = c.inside
                c.inside = node.ifaces.map(\.name).filter { kept.contains($0) || $0 == iface }
            case .outside: c.outside = iface
            }
            await self.editNow([.setNat(node: id, config: c.inside.isEmpty && c.outside == nil ? nil : c)], key: "nat:\(id)")
        }
    }

    /// Appends a rule typed in the Servizi tab (blank addresses: any; blank port: any port). Returns false, with the error under
    /// the rule form, if refused.
    @discardableResult
    public func addFirewallRule(_ id: String, _ rule: FirewallRule, port: String) async -> Bool {
        await serialized {
            let key = "fw:\(id)"
            guard var config = self.snapshot.nodes.first(where: { $0.id == id })?.firewall else { return false }
            let anyIfBlank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty ? "any" : s.trimmingCharacters(in: .whitespaces) }
            var r = rule
            r.src = anyIfBlank(r.src)
            r.dst = anyIfBlank(r.dst)
            let p = port.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty {
                guard let n = Int(p) else {
                    self.error = EditorError(key: key, message: "Invalid number: \"\(port)\"")
                    return false
                }
                r.port = n
            }
            config.rules.append(r)
            return await self.editNow([.setFirewall(node: id, config: config)], key: key)
        }
    }

    public func removeFirewallRule(_ id: String, at index: Int) async {
        await serialized {
            guard var config = self.snapshot.nodes.first(where: { $0.id == id })?.firewall, config.rules.indices.contains(index) else { return }
            config.rules.remove(at: index)
            await self.editNow([.setFirewall(node: id, config: config)], key: "fw:\(id)")
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh 2>&1 | tail -5`
Expected: all pass (2 more than before this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/PacKit/Topology+Helpers.swift Sources/PacKit/Editor.swift Tests/PacKitTests/NatFirewallEditorTests.swift
git commit -m "feat(kit): set NAT roles, add and remove firewall rules from typed fields, save NAT and firewall

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: App — NAT and Firewall in Servizi, Traduzioni NAT in Tabelle, selftest

**Files:**
- Modify: `Sources/PacTrack/ServicesTab.swift`, `Sources/PacTrack/InspectorView.swift`, `Sources/PacTrack/SelfTest.swift`

**Interfaces:**
- Consumes: Task 4 (`NatRole`, `natRole`, `FirewallAction.label`, `ruleSummary`, `Editor.setNatRole/addFirewallRule/removeFirewallRule`), Task 3 (`.setFirewall`, `NodeView.nat/.natTable/.firewall`), Task 2 (`FirewallConfig`, `FirewallRule`, `FirewallDirection`, `FirewallProto`), existing `ErrorLine`, `TableSection`, `Theme`, `SelfTest.render/sibling`.

- [ ] **Step 1: Baseline image**

Run: `scripts/selftest.sh build/m5-before.png` → `SELFTEST OK`; Read `build/m5-before.png`.

- [ ] **Step 2: Write the failing selftest scenario**

In `Sources/PacTrack/SelfTest.swift`, in `scenario(output:)` after `failures += await trafficScenario(output: output)` add:

```swift
        failures += await natScenario(output: output)
```

and add to `SelfTest`:

```swift
    /// M5: PC1 behind R1's NAT (inside Gi0/0, outside Gi0/1) reaches SRV1, which knows no route back; R1's firewall (default deny,
    /// anything entering Gi0/0 allowed) lets the replies through but not SRV1's own ping.
    private static func natScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.router, at: Pos(x: 560, y: 300))
        await editor.addDevice(.server, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("PC1"), id("R1")) // PC1 eth0 — R1 Gi0/0
        await editor.connect(id("R1"), id("SRV1")) // R1 Gi0/1 — SRV1 eth0
        for (name, iface, cidr) in [("PC1", "eth0", "192.168.1.10/24"), ("R1", "Gi0/0", "192.168.1.1/24"), ("R1", "Gi0/1", "203.0.113.1/24"),
                                    ("SRV1", "eth0", "203.0.113.10/24")] {
            await editor.edit(.setIp(node: id(name), iface: iface, cidr: cidr))
        }
        await editor.edit(.addRoute(node: id("PC1"), cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
        await editor.setNatRole(id("R1"), iface: "Gi0/0", .inside)
        await editor.setNatRole(id("R1"), iface: "Gi0/1", .outside)
        await editor.edit(.setFirewall(node: id("R1"), config: FirewallConfig(defaultAction: .deny)))
        await editor.addFirewallRule(id("R1"), FirewallRule(iface: "Gi0/0", direction: .inbound, action: .allow, proto: .any, src: "", dst: ""), port: "")
        await editor.edit(.setSink(node: id("SRV1"), on: true))
        await editor.run(.ping(node: id("PC1"), target: "203.0.113.10"))
        await editor.startTraffic(id("PC1"), target: "203.0.113.10", kind: .tcp, amount: "100000", seconds: "")
        await editor.run(.ping(node: id("SRV1"), target: "203.0.113.1"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if !(apps.first?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false) { failures.append("NAT ping \(apps.first?.lines ?? [])") }
        if apps.count != 3 || apps[1].lines.last != "iperf Done." { failures.append("NAT traffic \(apps.map(\.lines))") }
        if apps.count == 3, apps[2].lines.contains(where: { $0.contains("bytes from") }) { failures.append("SRV1 pinged R1 through the firewall") }
        let r1 = editor.snapshot.nodes.first { $0.name == "R1" }
        if Set(r1?.natTable.map(\.proto) ?? []) != ["icmp", "tcp"] { failures.append("NAT table \(r1?.natTable ?? [])") }
        if !editor.events.contains(where: { $0.kind == .tx && $0.node == id("R1") && $0.info.hasPrefix("203.0.113.1 → 203.0.113.10 Echo request") }) {
            failures.append("no translated echo request leaving R1")
        }
        if !editor.events.contains(where: { $0.reason == "firewall-default" && $0.node == id("R1") }) { failures.append("no firewall drop") }
        editor.select(.node(id("R1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m5")) { failures.append("could not write the M5 services image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m5-tables")) { failures.append("could not write the M5 tables image") }
        return failures
    }
```

- [ ] **Step 3: Run it to verify the engine checks pass but the images lack the UI**

Run: `scripts/selftest.sh build/selftest.png`
Expected: `SELFTEST OK` (engine and editor already work); Read `build/selftest-m5.png`: R1's Servizi tab shows only the DHCP server, and `build/selftest-m5-tables.png` no NAT table — the RED for this UI task is visual, as in M3 and M4.

- [ ] **Step 4: Implement the UI**

`Sources/PacTrack/ServicesTab.swift`:

The doc comment becomes `/// DHCP server (routers, servers), DNS server and sink (servers), NAT and firewall (routers): settings plus live tables (spec §7.1 ④).`

After `@State private var ttl = ""` add:

```swift
    @State private var ruleIface = "Gi0/0"
    @State private var ruleDirection = FirewallDirection.inbound
    @State private var ruleAction = FirewallAction.deny
    @State private var ruleProto = FirewallProto.any
    @State private var ruleSrc = ""
    @State private var ruleDst = ""
    @State private var rulePort = ""
```

The body's `if node.kind == .server { … }` block is followed by:

```swift
            if node.kind == .router {
                nat
                firewall
            }
```

Add to `ServicesTab`:

```swift
    private var nat: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAT / PAT (overload)").foregroundStyle(Theme.fgStrong)
            ForEach(node.ifaces, id: \.name) { iface in
                HStack {
                    Text(iface.name).font(Theme.mono)
                    Spacer()
                    Picker("", selection: Binding(get: { natRole(node.nat, iface.name) }, set: { role in
                        Task { await editor.setNatRole(node.id, iface: iface.name, role) }
                    })) {
                        ForEach(NatRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("nat-\(iface.name)")
                }
            }
            ErrorLine(editor: editor, key: "nat:\(node.id)")
            Text(node.nat?.outside != nil && node.nat?.inside.isEmpty == false
                 ? "Chi entra da una inside esce dalla outside con il suo indirizzo. Traduzioni in Tabelle."
                 : "Spento: serve una outside e almeno una inside.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private var firewall: some View {
        let key = "fw:\(node.id)"
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Firewall", isOn: Binding(get: { node.firewall != nil }, set: { on in
                Task { await editor.edit(.setFirewall(node: node.id, config: on ? FirewallConfig() : nil), key: key) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("firewall-enabled")
            if let config = node.firewall {
                HStack {
                    Text("Policy predefinita").font(Theme.small).foregroundStyle(Theme.muted)
                    Picker("", selection: Binding(get: { config.defaultAction }, set: { action in
                        var next = config
                        next.defaultAction = action
                        Task { await editor.edit(.setFirewall(node: node.id, config: next), key: key) }
                    })) {
                        ForEach(FirewallAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("firewall-default")
                }
                Text("REGOLE (DECIDE LA PRIMA CHE CORRISPONDE)").font(.system(size: 9)).foregroundStyle(Theme.muted)
                if config.rules.isEmpty { Text("nessuna").font(Theme.small).foregroundStyle(Theme.muted) }
                ForEach(config.rules.indices, id: \.self) { i in
                    HStack {
                        Text("\(i + 1). \(ruleSummary(config.rules[i]))").font(Theme.mono).lineLimit(1)
                        Spacer()
                        Button { Task { await editor.removeFirewallRule(node.id, at: i) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Rimuovi regola")
                    }
                }
                HStack {
                    Picker("", selection: $ruleIface) { ForEach(node.ifaces, id: \.name) { Text($0.name).tag($0.name) } }
                    Picker("", selection: $ruleDirection) { ForEach(FirewallDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("", selection: $ruleAction) { ForEach(FirewallAction.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Picker("", selection: $ruleProto) { ForEach(FirewallProto.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                HStack {
                    TextField("sorgente", text: $ruleSrc).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("destinazione", text: $ruleDst).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("porta", text: $rulePort).textFieldStyle(.roundedBorder).font(Theme.mono).frame(width: 50)
                    Button("+") {
                        Task {
                            let rule = FirewallRule(iface: ruleIface, direction: ruleDirection, action: ruleAction, proto: ruleProto,
                                                    src: ruleSrc, dst: ruleDst)
                            if await editor.addFirewallRule(node.id, rule, port: rulePort) {
                                ruleSrc = ""
                                ruleDst = ""
                                rulePort = ""
                            }
                        }
                    }
                    .accessibilityIdentifier("firewall-add")
                }
                ErrorLine(editor: editor, key: key)
                Text(config.defaultAction == .deny
                     ? "Passano solo le regole «consenti» e le risposte ai flussi consentiti, anche verso il router (DHCP, ping)."
                     : "Indirizzi: any, un IP o un prefisso. Le risposte ai flussi consentiti passano sempre.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            } else {
                Text("Spento: \(node.name) inoltra tutto.").font(Theme.small).foregroundStyle(Theme.muted)
                ErrorLine(editor: editor, key: key)
            }
        }
    }
```

`Sources/PacTrack/InspectorView.swift` — in `tables`, after the `TableSection(title: "Connessioni TCP", …)` line add:

```swift
                if node.nat != nil {
                    // Five wide columns: scroll sideways rather than squeeze addresses into the 300 pt column.
                    ScrollView(.horizontal) {
                        TableSection(title: "Traduzioni NAT", head: ["Proto", "Inside locale", "Inside globale", "Outside", "TTL"],
                                     rows: node.natTable.map { [$0.proto, $0.insideLocal, $0.insideGlobal, $0.outside, "\($0.ttlS)s"] })
                    }
                }
```

- [ ] **Step 5: Verify**

Run: `scripts/selftest.sh build/selftest.png` → `SELFTEST OK`. Read `build/selftest-m5.png` (R1 Servizi: DHCP off, NAT rows `Gi0/0 inside`, `Gi0/1 outside`, `Gi0/2`/`Gi0/3` `—` and the "Chi entra da una inside…" line; Firewall on, default *nega*, rule `1. in Gi0/0 · consenti any any → any`, the rule form and the deny hint; the event list shows `[firewall-default]` lines) and `build/selftest-m5-tables.png` (Tabelle with *Traduzioni NAT*: an `icmp` and a `tcp` row, `192.168.1.10:…` → `203.0.113.1:…`, outside `203.0.113.10:…`, TTL in seconds). If the rule form's four pickers or a rule line overflow the 300 pt inspector, split the pickers into two `HStack`s of two and re-check. Also `scripts/test.sh` stays green.

- [ ] **Step 6: Commit**

```bash
git add Sources/PacTrack/ServicesTab.swift Sources/PacTrack/InspectorView.swift Sources/PacTrack/SelfTest.swift
git commit -m "feat(app): configure NAT roles and the firewall in Servizi, show NAT translations in Tabelle

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Manual checklist and bundle

**Files:**
- Create: `docs/manual-checks/m5.md`

- [ ] **Step 1: Write the checklist**

```markdown
# M5 — manual checks

Build and open: `scripts/bundle.sh && open build/PacTrack.app`. Start from PC1 (192.168.1.10/24, gateway 192.168.1.1) cabled to R1 Gi0/0 (192.168.1.1/24), and R1 Gi0/1 (203.0.113.1/24) cabled to a Server SRV1 (203.0.113.10/24, no gateway, sink on).

**NAT**
- [ ] Without NAT, PC1 ▸ App ▸ Ping `203.0.113.10`: 100 % loss — SRV1 receives the requests but has no route back to 192.168.1.0/24 (`[no-route]` drop at SRV1).
- [ ] R1 ▸ Servizi ▸ NAT: Gi0/0 *inside*, Gi0/1 *outside*; each is one Cmd+Z step; the line under the table reads "Chi entra da una inside esce dalla outside…".
- [ ] Ping again: 4 received. The event list shows the request leaving R1 Gi0/1 as `203.0.113.1 → 203.0.113.10 Echo request id=… seq=…` with PC1's id. Click it: IPv4 source 203.0.113.1 and a header checksum different from PC1's frame; ICMP checksum present.
- [ ] R1 ▸ Tabelle ▸ *Traduzioni NAT*: `icmp  192.168.1.10:<id>  203.0.113.1:<id>  203.0.113.10:0`, TTL counting down from 60 s; the row disappears a minute after the last ping.
- [ ] PC1 ▸ App ▸ TCP 1000000 bytes to 203.0.113.10: `iperf Done.`; SRV1 ▸ Tabelle ▸ *Connessioni TCP* during the transfer shows remote `203.0.113.1:<port>`; R1's `tcp` row keeps the same port inside and global and, once the transfer ends, a TTL of at most 60 s.
- [ ] UDP 1 Mb/s for 2 s: `0/171 (0%)`; the `udp` row's TTL starts at 300 s.
- [ ] Traceroute from PC1 to 203.0.113.10: hop 1 `192.168.1.1`, hop 2 `203.0.113.10`. The *Destination unreachable (port)* leaving R1 towards PC1 goes to 192.168.1.10.
- [ ] SRV1 ▸ Ping `203.0.113.1`: answered by R1 itself. SRV1 ▸ TCP to 203.0.113.1: `Connection refused` (`[RST, ACK]` from R1). Nothing reaches PC1.
- [ ] Set Gi0/2 *outside*: Gi0/1 goes back to `—`. Set every interface to `—`: NAT off, the table disappears from Tabelle. Cmd+Z restores it.
- [ ] Power R1 off and on: the table is empty, the roles are kept.

**Firewall**
- [ ] R1 ▸ Servizi ▸ *Firewall* on: default *consenti*, no rules; ping and TCP still work.
- [ ] Rule `in Gi0/0 nega icmp` with destination `203.0.113.10`: PC1's ping loses everything and the events show `[firewall-rule] 192.168.1.10 → 203.0.113.10 Echo request …` at R1 Gi0/0 — before NAT, so with the private source. Ping `203.0.113.1` (R1 itself) still works.
- [ ] Add `in Gi0/0 consenti icmp`, then remove rule 1: the ping works again (the first match decides).
- [ ] Default *nega* with the single rule `in Gi0/0 consenti any`: PC1's ping, TCP transfer and traceroute still work (replies and ICMP errors pass); SRV1's ping to 203.0.113.1 shows `[firewall-default]` at R1 Gi0/1.
- [ ] Remove the allow rule, add `in Gi0/0 nega tcp` port `9`, then `in Gi0/0 consenti any`: the TCP transfer shows its `[SYN]` dropped at 0, 1, 3 … s (`[firewall-rule]`); UDP to port 9 still passes.
- [ ] Rule form: port `abc` → `Invalid number: "abc"`; port with ICMP → `A port needs TCP or UDP`; source `10.0.0` → `Invalid IPv4 address: "10.0.0"`; nothing is added.
- [ ] Cmd+Z after adding a rule removes it (one step); the firewall toggle and the default policy are one step each.
- [ ] Save, close, reopen: NAT roles, rules and default policy are back; the NAT table starts empty.
```

- [ ] **Step 2: Full verification**

Run: `scripts/test.sh 2>&1 | tail -3` (all pass), `scripts/selftest.sh build/selftest.png` (`SELFTEST OK`), `scripts/bundle.sh`, then launch `build/PacTrack.app/Contents/MacOS/PacTrack` in the background for ~5 s, confirm it is running (`pgrep -x PacTrack`) and its log is empty, kill it.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-checks/m5.md
git commit -m "docs: add the M5 manual checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Out of scope (recorded)

- NAT: static NAT and port forwarding (`ip nat inside source static`), address pools, source ACLs, several outside interfaces, hairpinning, translating inside-originated echo replies and ICMP errors, ALGs, IOS port-range classes and port parity — added when a lab needs a reachable inside server.
- Firewall: source ports, port ranges, rule reordering (remove and re-add), per-interface default policies, a TCP state machine (SYN-only flow creation), ICMP administratively-prohibited replies, per-rule hit counters, a flow (conntrack) table in the UI, host firewalls.
- Cloud/ISP device (spec §5.5): not part of milestone M5 in §11; to be scheduled with the user.
- No new context-menu entries (spec §7.2 lists none for NAT or firewall); copying a router does not copy NAT or the firewall (as DHCP/DNS).
