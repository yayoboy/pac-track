# M9b — IPv6 services: DNS AAAA, RDNSS, TCP and UDP, firewall (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The services of M3–M5 work over IPv6 (spec M9 §10):
- TCP (M4) and the dual-stack UDP services (sink, DNS) run over IPv6; the traffic generator takes IPv6 addresses and names; the Connessioni TCP show `[address]:port`;
- the DNS server answers AAAA records (RFC 3596) on both stacks, the resolver asks A and AAAA (getaddrinfo with AI_ADDRCONFIG) and picks the AAAA when the device has a global IPv6 address, `nslookup` shows both;
- routers advertise a DNS server in their RAs (RDNSS, RFC 8106), hosts learn it after the typed and the DHCP server;
- firewall rules take IPv6 addresses and prefixes, ICMP rules cover ICMPv6, flows are tracked for IPv6, NS and NA always pass;
- the two deferred M9a Minors: a zone in a ping target gives the typed error, the static-route form says it takes IPv6.

**Architecture:**
- `IpAddr` (`.v4(UInt32)`, `.v6(UInt128)`) in `Address.swift` is the one new address type: TCP connection ends, DNS records and resolutions, the generator's targets. IPv4-only APIs stay as they are (NAT, `Endpoints` for NAT, `bindUdp`, `sendUdp(UInt32…)`), so the IPv4 paths and tests do not change.
- `Ipv6Payload` gains `.tcp`; `Ipv6.deliver` hands TCP to `IpNode.tcp` and UDP to the ports bound on both stacks (`IpNode.bindUdp(_:both:)`, table `udp6`).
- `Endpoints` becomes generic over the address type, so the firewall tracks IPv4 and IPv6 flows with one generic decision; `Ipv6.input`/`send` call the firewall like `IpNode.input`/`output` do.
- `RouterAdvert.dns` carries RDNSS; `Ipv6.rdnss` (routers) and `Ipv6.dnsServer` (hosts) feed `IpNode.effectiveNameServer`, now an `IpAddr?`.
- `Command.setRdnss`, `NodeView.rdnss`, `TopologyNode.rdnss` carry the router setting to `PacKit` and `PacTrack`.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (macOS 15), Observation, Swift Testing, SwiftPM, Command Line Tools only — no Xcode.

**Spec:** `docs/superpowers/specs/2026-10-11-m9-ipv6-design.md` §10 and the M9b part of §11 (with the *Decisione (M9b)* lines added in §10), plus the two Minors deferred by the M9a review (`.superpowers/sdd/2026-10-11-m9a-ipv6-core/progress.md`). It extends `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (rev. 2), M3, M4, M5 and M9a.

Conventions: `docs/superpowers/plans/2026-10-11-m9a-ipv6-core.md`; ledger `.superpowers/sdd/2026-10-11-m9b-ipv6-services/progress.md` in the style of `.superpowers/sdd/2026-10-11-m9a-ipv6-core/progress.md`.

## Global Constraints

- **Running commands.** Every `swift`/`scripts/*.sh` command runs **outside the sandbox**. Unit tests only via `scripts/test.sh` (bare `swift test` runs zero tests with CLT); one suite with `scripts/test.sh --filter <Suite>`. End-to-end: `scripts/selftest.sh build/selftest.png` must print `SELFTEST OK`. Baseline: `✔ Test run with 385 tests in 51 suites passed`.
- **Git.** Work in place on branch `m9/ipv6`; never switch branches, never push, no PRs. Stage only the files a task lists, one conventional commit per task, trailer:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VKg7UVJhJdqPhWvu8DgXn7
  ```
- **Engine rules.** The Sim owns its nodes; node→sim is `unowned`. Never store `SimTimer`s (deadlines checked in callbacks). The UI holds only `Snapshot` values and string ids. Removed nodes stay alive while frames are in flight. Guard numeric conversions (`truncatingIfNeeded`). Tests keep the `Sim` alive while nodes run.
- **Determinism.** No randomness beyond `sim.rng`; never iterate a `Dictionary` where order is observable (the resolver merges by a fixed type order).
- **IPv4 unchanged.** Existing tests keep their assertions. The one exception is M9a's `natAndTheFirewallLeaveIpv6Alone`, whose firewall now filters IPv6 by spec (§10 *Decisione (M9b)*: the policy covers IPv6): it gains an IPv6 allow rule.
- **Edits.** Every network change goes through `Editor.edit`; undo stays the Editor's serialized stacks.
- **`.ptk`.** `Topology.version` stays `1`. New optional key `rdnss` on `TopologyNode` (absent: none). DNS records and firewall rules keep their string fields; an address with `:` is IPv6.
- **Protocol fidelity (spec §10).**
  - TCP over IPv6: next header 6, checksum over the IPv6 pseudo-header (RFC 8200 §8.1), MSS 1440 (RFC 8200 §8.3).
  - UDP over IPv6: checksum mandatory (already in `makeIpv6`); the generator's datagram carries 1450 B.
  - DNS: type A 1, AAAA 28 (RFC 3596 §2.1); an AAAA answer is 28 B (pointer, type, class, TTL, length, 16 B); NODATA is NOERROR with no answers; NXDOMAIN only for unknown names.
  - RDNSS (RFC 8106 §5.1): option type 25, length 3 (one address, 24 B), reserved 0, lifetime 600 s; lifetime 0 withdraws the server.
  - Firewall: NS (135) and NA (136) never filtered; RS and RA filtered like any packet; drops are silent.
- **Copy and style.** User-facing copy Italian; engine error messages English; code, comments, tests, commits English. Colours only via `Theme`.
- **Ponytail/YAGNI.** Every API below has a consumer in this plan; nothing for later milestones. Deliberate shortcuts carry a `ponytail:` comment naming the ceiling.
- **Out of scope (spec §10):** DHCPv6, reverse names (`ip6.arpa`), DNS over TCP, NAT for IPv6, more than one RDNSS server, the RFC 8106 DNSSL option.

## Review Focus

1. **IPv4-only labs.** No AAAA query leaves a device without a global IPv6 address (nslookup: without IPv6 on); DNS, TCP, UDP and the firewall behave as before. Pinned by the full suite and `namesResolveToTheAaaaOnlyWhenTheDeviceHasAGlobalIpv6Address` (Task 4).
2. **The MTU over IPv6.** The 20 extra header bytes must not turn every full TCP segment or generator datagram into a Packet Too Big. Pinned by `tcpRunsOverIpv6WithAnMssOf1440AndResetsAClosedPort` (Task 2) and `theTrafficGeneratorRunsTcpAndUdpToAnIpv6Address` (Task 3), both with `drops(sim, .mtuExceeded) == 0`.
3. **A deny-all firewall on an IPv6 router.** Address resolution keeps working (NS/NA pass), RSs are dropped but the hosts still configure from the router's own RAs, replies and ICMPv6 errors of allowed flows get back. Pinned by `ipv6FlowsAreTrackedAndNeighbourDiscoveryIsNeverFiltered` (Task 6).
4. **Names with only one record type.** A name with only A (or only AAAA) answers NODATA for the other type; nslookup, ping and the generator fall back to what exists; unknown names stay NXDOMAIN. Pinned by `theServerAnswersAaaaOnBothStacksAndNslookupShowsAAndAaaa` (Task 4).
5. **Where the name server comes from.** Typed beats DHCP beats RDNSS; an RDNSS server disappears 600 s after the last RA that carried it and at once with lifetime 0. Pinned by `routersAdvertiseTheirDnsServerAndHostsUseItLast` (Task 5).

## Spec coverage

| M9 spec | Task |
|---|---|
| deferred M9a Minor: zone in a ping/traceroute target | 1 |
| §10 UDP and TCP over IPv6 (connections, sink, Port Unreachable), §11 TCP/UDP checksums with the pseudo-header | 2 |
| §10 generator over IPv6, Connessioni TCP `[address]:port` | 3 |
| §10 DNS AAAA, server on IPv6, nslookup A + AAAA, choice of the address for a name | 4 |
| §10 RDNSS (router setting, RA option, host learning, precedence), §9-style persistence | 5 |
| §10 firewall IPv6 (rules, ICMPv6, stateful, NS/NA never filtered) | 6 |
| deferred M9a Minor: the static-route form takes IPv6 | 7 |
| §10 UI (RDNSS field, AAAA records, firewall copy, learned server), §11 selftest images | 8 |
| §11 manual checks | 9 |

## Rulings (where the spec is silent)

Each line gives the ruling, why, and the cost if wrong.

- **`IpAddr` only where both versions meet.** TCP ends, DNS records, resolutions and generator targets use it; `nameServer`, `learnedNameServer`, NAT, `bindUdp`, `sendUdp(UInt32…)` and `Tcp.connect(to: UInt32…)` stay IPv4 (the last as a one-line overload). Why: the existing IPv4 tests call these with integer literals. Cost if wrong: two overloads.
- **Dual-stack UDP ports.** `IpNode.bindUdp(_:both:)` binds the IPv4 port and registers an IPv6 handler in `udp6`; ports bound the old way stay IPv4-only (DHCP, RIP). Why: Linux's dual-stack sockets; one port namespace for conflicts. Cost if wrong: none.
- **`DnsAnswer.addr` is a `UInt128`**, an A's 32 bits or an AAAA's 128, read through `DnsMessage.address(_:)` by the question's type. Why: the wire RDATA is 4 or 16 bytes of the question's type; existing tests build answers from integer literals. Cost if wrong: none on the wire.
- **The resolver's AAAA and A are two queries from two ports,** sent back to back (glibc uses one socket). Why: one `DnsQuery` per question keeps the retry logic as it is. Cost if wrong: one more ephemeral port per lookup.
- **NODATA reaches `merged` as `.found([])`**; with no address at all a resolution is `.nxdomain` unless a query failed. Why: getaddrinfo reports "Name or service not known" either way, as before. Cost if wrong: the wording for a name that exists without addresses.
- **nslookup prints `*** Can't find <name>: No answer`** only when neither type had an address. Cost if wrong: one line.
- **RDNSS lives on the router node** (`Ipv6.rdnss`), advertised on every interface that sends RAs; set from the Routing tab, shown only while `ipv6 unicast-routing` is on. Cost if wrong: none.
- **The view's `learnedNameServer` is DHCP's, else RDNSS's;** the inspector says "(da DHCP)" or "(da RA)" by the address's version (DHCP is IPv4-only, RDNSS IPv6-only). Why: no new view field. Cost if wrong: none.
- **`Endpoints<Addr>` is generic;** NAT keeps `Endpoints<UInt32>`, the firewall keeps two flow lists and one generic `decide`. Cost if wrong: none.
- **The firewall checks IPv6 like IPv4:** packets for the router (unicast and joined groups) on input, forwarded ones after the route lookup with the hop limit already decremented, the router's own packets tracked, never filtered.
- **The traffic generator refuses link-local and multicast IPv6 targets** with the ping error shape (`Traffic to link-local or multicast addresses is not supported`), through the same `ipv6Target` helper. Cost if wrong: none.

---

### Task 1: Engine — a zone in a ping or traceroute target gives the typed error (deferred M9a Minor)

**Files:**
- Modify: `Sources/PacEngine/Apps/Ping.swift` (`ipv6Target`, `Ping.init`)
- Modify: `Sources/PacEngine/Apps/Traceroute.swift` (`Traceroute.init`)
- Test: `Tests/PacEngineTests/Ipv6ServicesTests.swift` (create)

**Interfaces:**
- Produces: `func ipv6Target(_ s: String, tool: String) throws -> UInt128?` (nil without a `:`; consumed by Task 3's traffic flows).

- [ ] **Step 1: Write the failing test.** Create `Tests/PacEngineTests/Ipv6ServicesTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct Ipv6ServicesTests {
    /// M9a review: "fe80::1%eth0" said "Invalid IPv6 address" instead of the typed error.
    @Test func zonesGetTheLinkLocalErrorAndNothingElse() throws {
        let sim = Sim()
        let a = Host(sim: sim, id: "A")
        withExtendedLifetime(sim) {
            expectError("Ping to link-local or multicast addresses is not supported") { _ = try Ping(node: a, target: "fe80::1%eth0") }
            expectError("Traceroute to link-local or multicast addresses is not supported") { _ = try Traceroute(node: a, target: "ff02::1%eth0") }
            expectError("Invalid IPv6 address: \"2001:db8::1%eth0\"") { _ = try Ping(node: a, target: "2001:db8::1%eth0") }
            expectError("Invalid IPv6 address: \"fe80::zz\"") { _ = try Ping(node: a, target: "fe80::zz%eth0") } // the address part is parsed first
        }
    }
}
```

- [ ] **Step 2: Run it.** `scripts/test.sh --filter Ipv6ServicesTests` → FAIL: the first two expectations get `Invalid IPv6 address: "fe80::1%eth0"` / `"ff02::1%eth0"`, the last `"fe80::zz%eth0"`.

- [ ] **Step 3: Implement.** In `Ping.swift`, after `errorText6`:

```swift
/// An IPv6 destination for ping, traceroute or the traffic generator (spec M9 §7): nil without a ":". Link-local and multicast
/// destinations are refused, with or without a zone ("fe80::1%eth0"), since Linux needs the zone and Pac-Track has none (§2);
/// a zone on any other address is not an address.
func ipv6Target(_ s: String, tool: String) throws -> UInt128? {
    guard s.contains(":") else { return nil }
    let a = try parseIp6(String(s.prefix { $0 != "%" }))
    if isLinkLocal6(a) || isMulticast6(a) { throw EngineError("\(tool) to link-local or multicast addresses is not supported") }
    if s.contains("%") { throw EngineError("Invalid IPv6 address: \"\(s)\"") }
    return a
}
```

In `Ping.init` replace

```swift
        let v6 = try target.contains(":") ? parseIp6(target) : nil
        if let v6, isLinkLocal6(v6) || isMulticast6(v6) { throw EngineError("Ping to link-local or multicast addresses is not supported") }
```

with `let v6 = try ipv6Target(target, tool: "Ping")`, and in `Traceroute.init` the same two lines with `let v6 = try ipv6Target(target, tool: "Traceroute")`.

- [ ] **Step 4: Run.** `scripts/test.sh --filter Ipv6ServicesTests` → PASS; full `scripts/test.sh` → 386 tests.
- [ ] **Step 5: Commit** `fix(engine): a zone in a ping or traceroute target gets the link-local error` (files above).

---

### Task 2: Engine — TCP and UDP over IPv6

**Files:**
- Modify: `Sources/PacEngine/Address.swift` (`IpAddr`)
- Modify: `Sources/PacEngine/Ipv6Pdu.swift` (`Ipv6Payload.tcp`)
- Modify: `Sources/PacEngine/L4/Tcp.swift`
- Modify: `Sources/PacEngine/L3/IpNode.swift` (`udp6`, `bindUdp(_:both:)`, `source(for:)`, sink, TCP delivery)
- Modify: `Sources/PacEngine/L3/Ipv6.swift` (`sourceFor`, delivery of TCP and UDP)
- Modify: `Sources/PacEngine/Runtime/EventViews.swift` (TCP over IPv6 in the list and the inspector)
- Test: `Tests/PacEngineTests/Ipv6ServicesTests.swift`

**Interfaces:**
- Consumes: Task 1's file.
- Produces: `enum IpAddr { case v4(UInt32), v6(UInt128); var text: String }`; `TCP_MSS6 = 1440`; `Ipv6Payload.tcp(TcpSegment)`; `TcpConnection.localIp/remoteIp: IpAddr`; `Tcp.connect(to: IpAddr, port:sending:)` (+ the `UInt32` overload), `Tcp.input(_:from:to:)`, `Tcp.send(_:from:to:)` with `IpAddr`; `IpNode.udp6`, `IpNode.bindUdp(_ port: UInt16, both: @escaping (IpAddr, IpAddr, UdpDatagram) -> Void) throws -> () -> Void`, `IpNode.source(for: IpAddr) -> IpAddr?`; `Ipv6.sourceFor(_ dst: UInt128) -> UInt128?`.

- [ ] **Step 1: Write the failing tests.** Add to `Ipv6ServicesTests.swift`, above the suite:

```swift
/// PC (H1, SLAAC) — R1 (Gi0/0 2001:db8:1::1/64 | Gi0/1 2001:db8:2::1/64, `ipv6 unicast-routing`) — SRV (H2, 2001:db8:2::53/64), dual
/// stack from `routedPair` (10.0.1.10 and 10.0.2.10), run to t = 3 s. MACs: H1 …:01, H2 …:02, R1 Gi0/0 …:03, Gi0/1 …:04.
private func lab() throws -> (sim: Sim, pc: Host, srv: Host, r1: Router) {
    let (sim, pc, srv, r1) = try routedPair()
    try r1.v6.configure("Gi0/0", Ipv6Config(address: "2001:db8:1::1/64"))
    try r1.v6.configure("Gi0/1", Ipv6Config(address: "2001:db8:2::1/64"))
    r1.v6.setRouting(true)
    try pc.v6.configure("eth0", Ipv6Config(autoconfig: true))
    try srv.v6.configure("eth0", Ipv6Config(address: "2001:db8:2::53/64"))
    sim.run(3 * S)
    return (sim, pc, srv, r1)
}

private let SRV = UInt128(0x2001_0DB8_0002) << 80 | 0x53 // 2001:db8:2::53
private let PC = "2001:db8:1::ff:fe00:1"

/// Every TCP segment received anywhere over IPv6, with its packet.
private func tcp6(_ sim: Sim) -> [(p: Ipv6Packet, t: TcpSegment)] {
    sim.log.all.compactMap { e in
        guard e.kind == .rx, case .ipv6(let p)? = e.frame?.payload, case .tcp(let t) = p.payload else { return nil }
        return (p, t)
    }
}

private func checksumHolds(_ p: Ipv6Packet) -> Bool {
    internetChecksum(pseudoHeader6(p.src, p.dst, p.payload.size, p.payload.nextHeader) + serializePayload(p)) == 0
}
```

(Task 5 gives `lab` an `rdnss: String? = nil` parameter, Task 6 a `firewall: FirewallConfig? = nil` one.) Tuple key paths are avoided below: closures read `$0.t`. Then, in the suite:

```swift
    @Test func tcpOverIpv6HasItsWireSizeAPseudoHeaderChecksumAndItsLayers() throws {
        let src = try parseIp6("2001:db8:1::10")
        let syn = makeIpv6(src: src, dst: SRV, hopLimit: 64,
                           payload: .tcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1, ack: 0, flags: [.syn], window: 65535, mss: 1440)))
        let full = makeIpv6(src: src, dst: SRV, hopLimit: 64,
                            payload: .tcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 2, ack: 7, flags: [.ack], window: 65535, dataLength: 1440)))
        #expect(syn.size == 64 && full.size == 1500 && syn.payload.nextHeader == IPPROTO_TCP)
        #expect(checksumHolds(syn) && checksumHolds(full)) // the zero data is not serialized, but its length is in the pseudo-header
        let e = SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: EthernetFrame(
            id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV6, payload: .ipv6(syn)))
        #expect(eventView(e).proto == .tcp && eventView(e).bytes == 78)
        #expect(eventView(e).info == "TCP 40000 → 9 [SYN] seq=1 win=65535 len=0 mss=1440 · 2001:db8:1::10 → 2001:db8:2::53")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv6", "TCP"])
        #expect(layers[1].fields.contains(PduField(name: "Next header", value: "6 (TCP)")))
        #expect(layers[2].fields.contains(PduField(name: "Opzione MSS", value: "1440 B")))
    }

    @Test func tcpRunsOverIpv6WithAnMssOf1440AndResetsAClosedPort() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureSink(true)
        let c = try pc.tcp.connect(to: .v6(SRV), port: 9, sending: 100_000)
        sim.run(5 * S)
        #expect(c.localIp == .v6(try parseIp6(PC)) && c.remoteIp == .v6(SRV))
        #expect(c.bytesAcked == 100_000 && c.doneAt != nil)
        let segments = tcp6(sim)
        #expect(Set(segments.compactMap { $0.t.mss }) == [1440]) // both SYNs
        #expect(segments.map { $0.t.dataLength }.max() == 1440)
        #expect(segments.allSatisfy { checksumHolds($0.p) })
        #expect(drops(sim, .mtuExceeded) == 0)
        try srv.configureSink(false)
        let refused = try pc.tcp.connect(to: .v6(SRV), port: 9, sending: 1000)
        sim.run(1 * S)
        #expect(refused.failure == .refused)
    }

    @Test func udpPortsBoundOnBothStacksTakeIpv6AndTheOthersAnswerPortUnreachable() throws {
        let (sim, pc, srv, _) = try lab()
        var got: [String] = []
        let unbind = try srv.bindUdp(5000, both: { src, dst, u in got.append("\(src.text) → \(dst.text) port \(u.dstPort)") })
        var codes: [UInt8] = []
        pc.v6.onIcmp { _, m in if m.type == ICMP6_DEST_UNREACH { codes.append(m.code) } }
        pc.v6.send(SRV, .udp(makeUdp(srcPort: 40000, dstPort: 5000, data: [1])))
        pc.v6.send(SRV, .udp(makeUdp(srcPort: 40000, dstPort: 5001, data: [1])))
        sim.run(1 * S)
        #expect(got == ["\(PC) → 2001:db8:2::53 port 5000"])
        #expect(codes == [UNREACH6_PORT])
        expectError("UDP port 5000 already in use") { try srv.bindUdp(5000) { _, _, _ in } }
        unbind()
        try srv.bindUdp(5000) { _, _, _ in }
    }
```

- [ ] **Step 2: Run.** `scripts/test.sh --filter Ipv6ServicesTests` → build error `type 'Ipv6Payload' has no member 'tcp'`.

- [ ] **Step 3: Implement.**

`Address.swift`, at the end:

```swift
/// An IPv4 or IPv6 address, where both versions meet: TCP connections, DNS records and answers, the traffic generator's targets
/// (spec M9 §10).
enum IpAddr: Equatable, Sendable {
    case v4(UInt32)
    case v6(UInt128)

    var text: String {
        switch self {
        case .v4(let a): formatIp(a)
        case .v6(let a): formatIp6(a)
        }
    }
}
```

`Ipv6Pdu.swift`: the payload gains TCP. Doc line becomes `/// What an IPv6 packet carries: ICMPv6 echo and errors (ICMPv4's header layout, so `IcmpMessage`), NDP, UDP, TCP.`; add `case tcp(TcpSegment)`; `size`: `case .tcp(let t): t.size`; `nextHeader`: `case .tcp: IPPROTO_TCP`; `serializePayload`: `case .tcp(let t): serialize(t)`; `makeIpv6`, after the UDP case:

```swift
    case .tcp(var t):
        t.checksum = 0
        t.checksum = internetChecksum(pseudo + serialize(t))
        sealed = .tcp(t)
```

and its doc: `/// A packet with its payload's checksum filled in: mandatory for ICMPv6, TCP and UDP over IPv6, where a UDP sum of 0 is sent as ffff.`

`Tcp.swift`:
- after `let TCP_MSS = 1460`: 
  ```swift
  /// Over IPv6 the header is 20 B longer: the MTU less 60 (RFC 8200 §8.3, spec M9 §10).
  let TCP_MSS6 = 1440
  ```
- `TcpConnection`: `let localIp: IpAddr`, `let remoteIp: IpAddr`; after `private var mss = TCP_MSS` add
  ```swift
      /// The MSS this end announces: the MTU less the IP and TCP headers.
      private let ownMss: Int
  ```
  init signature `init(tcp: Tcp, local: IpAddr, localPort: UInt16, remote: IpAddr, remotePort: UInt16, sending bytes: Int, state: TcpState)`, and in its body after `self.remotePort = remotePort`:
  ```swift
          ownMss = if case .v6 = local { TCP_MSS6 } else { TCP_MSS }
          mss = ownMss
  ```
- `learn`: `mss = min(ownMss, Int(syn.mss ?? UInt16(TCP_DEFAULT_MSS)))`.
- `send` (connection): `mss: flags.contains(.syn) ? UInt16(ownMss) : nil`.
- `Tcp.connect`:
  ```swift
      /// Active open from a random ephemeral port (Linux range 32768–60999): sends `bytes`, then closes.
      func connect(to dst: IpAddr, port: UInt16, sending bytes: Int) throws -> TcpConnection {
          guard let src = node.source(for: dst) else { throw EngineError("Network is unreachable") }
          … (loop unchanged)
      }

      /// An IPv4 destination.
      func connect(to dst: UInt32, port: UInt16, sending bytes: Int) throws -> TcpConnection {
          try connect(to: .v4(dst), port: port, sending: bytes)
      }
  ```
- `input`, `refuse`, `send` and a helper:
  ```swift
      /// A segment from either stack.
      func input(_ s: TcpSegment, from src: IpAddr, to dst: IpAddr) {
          guard owns(dst) else { return } // never to a broadcast or multicast address
          if let c = connections.first(where: {
              $0.localIp == dst && $0.localPort == s.dstPort && $0.remoteIp == src && $0.remotePort == s.srcPort
          }) {
              return c.receive(s)
          }
          if s.flags.contains(.rst) { return }
          if s.flags == [.syn], listening.contains(s.dstPort) {
              let c = TcpConnection(tcp: self, local: dst, localPort: s.dstPort, remote: src, remotePort: s.srcPort, sending: 0,
                                    state: .synReceived)
              connections.append(c)
              return c.accept(s)
          }
          refuse(s, from: src, to: dst)
      }

      private func owns(_ a: IpAddr) -> Bool {
          switch a {
          case .v4(let a): node.ownsIp(a)
          case .v6(let a): node.v6.owns(a)
          }
      }

      /// RFC 793 "Reset Generation": a segment for no connection gets a RST its sender will accept.
      private func refuse(_ s: TcpSegment, from src: IpAddr, to dst: IpAddr) {
          … (body unchanged except the last line)
          send(rst, from: dst, to: src)
      }

      func send(_ s: TcpSegment, from src: IpAddr, to dst: IpAddr) {
          switch (src, dst) {
          case let (.v4(a), .v4(b)): node.sendPacket(b, .tcp(makeTcp(s, src: a, dst: b)), src: a)
          case let (.v6(a), .v6(b)): node.v6.send(b, .tcp(s), src: a) // makeIpv6 fills the checksum
          default: break // a connection's ends are always of one version
          }
      }
  ```

`IpNode.swift`:
- after `private var udp: [UInt16: UdpHandler] = [:]`:
  ```swift
      /// The ports bound on both stacks also take IPv6 datagrams (spec M9 §10).
      private(set) var udp6: [UInt16: (Ipv6Packet, UdpDatagram) -> Void] = [:]
  ```
- after `bindUdp`:
  ```swift
      /// A UDP port on both stacks, like a Linux dual-stack socket: the handler gets each datagram's source and destination.
      func bindUdp(_ port: UInt16, both handler: @escaping (IpAddr, IpAddr, UdpDatagram) -> Void) throws -> () -> Void {
          let unbind = try bindUdp(port) { p, u, _ in handler(.v4(p.src), .v4(p.dst), u) }
          udp6[port] = { p, u in handler(.v6(p.src), .v6(p.dst), u) }
          return { [weak self] in
              unbind()
              self?.udp6[port] = nil
          }
      }
  ```
- after `sourceFor`:
  ```swift
      /// Either stack's source address toward `dst`; nil without a route.
      func source(for dst: IpAddr) -> IpAddr? {
          switch dst {
          case .v4(let a): sourceFor(a).map(IpAddr.v4)
          case .v6(let a): v6.sourceFor(a).map(IpAddr.v6)
          }
      }
  ```
- `configureSink`: the UDP bind becomes `unbind = try bindUdp(PORT_DISCARD, both: { [unowned self] _, _, u in if case .traffic(let d) = u.payload { self.sim.flows[d.flow]?(d) } })` (multi-line as before).
- `deliver`: `case .tcp(let t): tcp.input(t, from: .v4(p.src), to: .v4(p.dst))`.

`Ipv6.swift`:
- after `send`:
  ```swift
      /// The source toward `dst`: itself when it is an own address; nil for a link-local destination (it needs an interface) or
      /// without a route.
      func sourceFor(_ dst: UInt128) -> UInt128? {
          if owns(dst) { return dst }
          guard !isLinkLocal6(dst), let hop = lookup(dst) else { return nil }
          return source(for: dst, out: hop.iface)
      }
  ```
- `deliver`: the UDP case becomes
  ```swift
          case .udp(let u):
              // A port bound on both stacks (spec M9 §10); otherwise Port Unreachable, as in IPv4.
              if let handler = node.udp6[u.dstPort] {
                  handler(p, u)
              } else if !isMulticast6(p.dst) {
                  error(p, type: ICMP6_DEST_UNREACH, code: UNREACH6_PORT, via: iface)
              }
          case .tcp(let t):
              node.tcp.input(t, from: .v6(p.src), to: .v6(p.dst))
  ```

`EventViews.swift`:
- `proto(of p: Ipv6Packet)`: `case .tcp: .tcp`.
- a shared summary, used by `describe(_ p: Ipv4Packet)` (`return "\(ends) TCP " + tcpSummary(t)`) and `describe(_ p: Ipv6Packet)` (`case .tcp(let t): "TCP " + tcpSummary(t)`):
  ```swift
  /// "40000 → 9 [SYN, ACK] seq=… ack=… win=65535 len=0 mss=1460".
  private func tcpSummary(_ t: TcpSegment) -> String {
      "\(t.srcPort) → \(t.dstPort) [\(flagNames(t.flags))] seq=\(t.seq)" + (t.flags.contains(.ack) ? " ack=\(t.ack)" : "")
          + " win=\(t.window) len=\(t.dataLength)" + (t.mss.map { " mss=\($0)" } ?? "")
  }
  ```
- `tcpLayer(_ t: TcpSegment) -> PduLayer`: the TCP fields block of `ipLayers` moved into its own function, used by `ipLayers` (`return [ip, tcpLayer(t)]`) and `ipv6Layers` (`case .tcp(let t): return [ip, tcpLayer(t)]`).
- `ipv6Layers` "Next header": `p.payload.nextHeader == IPPROTO_UDP ? "17 (UDP)" : p.payload.nextHeader == IPPROTO_TCP ? "6 (TCP)" : "58 (ICMPv6)"`.

- [ ] **Step 4: Run.** `scripts/test.sh --filter Ipv6ServicesTests` → PASS; full suite → 389 tests; `swift build` (app) builds.
- [ ] **Step 5: Commit** `feat(engine): TCP and dual-stack UDP ports over IPv6` (files above).

---

### Task 3: Engine — the traffic generator over IPv6, Connessioni TCP with `[address]:port`

**Files:**
- Modify: `Sources/PacEngine/PDU.swift` (`TrafficData.bytes`, `TRAFFIC_DATAGRAM6`)
- Modify: `Sources/PacEngine/Apps/Traffic.swift`
- Modify: `Sources/PacEngine/L3/IpNode.swift` (`sendUdp(_: IpAddr…)`)
- Modify: `Sources/PacEngine/Runtime/EventViews.swift` (the datagram's size)
- Modify: `Sources/PacEngine/Runtime/Runtime.swift` (`tcpRows`)
- Test: `Tests/PacEngineTests/Ipv6ServicesTests.swift`, `Tests/PacEngineTests/RuntimeIpv6ServicesTests.swift` (create)

**Interfaces:**
- Consumes: Task 1 `ipv6Target`; Task 2 `IpAddr`, `Tcp.connect(to: IpAddr…)`, `IpNode.source(for:)`, the dual-stack sink.
- Produces: `IpNode.sendUdp(_ dst: IpAddr, srcPort: UInt16, dstPort: UInt16, payload: UdpPayload, src: IpAddr? = nil) -> Bool` (`@discardableResult`); `TrafficData.bytes`; `TRAFFIC_DATAGRAM6 = 1450`; `TcpFlow.begin(_: IpAddr)`, `UdpFlow.begin(_: IpAddr)` (private, called from `resolved` in Task 4).

- [ ] **Step 1: Write the failing tests.** In `Ipv6ServicesTests`:

```swift
    @Test func theTrafficGeneratorRunsTcpAndUdpToAnIpv6Address() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureSink(true)
        let tcp = try TcpFlow(node: pc, target: "2001:db8:2::53", bytes: 100_000)
        let udp = try UdpFlow(node: pc, target: "2001:DB8:2::53", bitsPerSecond: 1e6, seconds: 1)
        sim.run(4 * S)
        #expect(tcp.result.lines.first == "Connecting to host 2001:db8:2::53, port 9")
        #expect(tcp.result.lines[1].hasPrefix("[  1] local \(PC) port ") && tcp.result.lines[1].hasSuffix(" connected to 2001:db8:2::53 port 9"))
        #expect(tcp.result.lines.last == "iperf Done.")
        #expect(udp.result.lines.contains { $0.hasSuffix("0/87 (0%)") }) // 1450 B every 11.6 ms for 1 s
        #expect(udp.result.lines.last == "iperf Done.")
        #expect(sim.log.all.contains { $0.kind == .rx && $0.node == "H2" && $0.frame?.size == 1512 }) // 14 + 40 + 8 + 1450
        #expect(drops(sim, .mtuExceeded) == 0)
        expectError("Traffic to link-local or multicast addresses is not supported") { _ = try TcpFlow(node: pc, target: "fe80::1", bytes: 1) }
    }
```

Create `Tests/PacEngineTests/RuntimeIpv6ServicesTests.swift`:

```swift
import Foundation
import Testing
@testable import PacEngine

private func runFor(_ rt: Runtime, ms: Int) {
    for _ in stride(from: 0, to: ms, by: 100) { rt.advance(wallMs: 100) }
}

/// The spec's M9b lab: PC1 — R1 — SRV1, R1 Gi0/0 2001:db8:1::1/64 and Gi0/1 2001:db8:2::1/64 with `ipv6 unicast-routing`, PC1 on
/// SLAAC, SRV1 2001:db8:2::53/64 with the sink. PC1's MAC is …:01, so its address is 2001:db8:1::ff:fe00:1.
private func lab() throws -> Runtime {
    let rt = Runtime()
    try rt.handle(.addNode(id: "a", kind: .pc, name: "PC1"))
    try rt.handle(.addNode(id: "r", kind: .router, name: "R1"))
    try rt.handle(.addNode(id: "s", kind: .server, name: "SRV1"))
    try rt.handle(.connect(id: "1", a: IfaceRef(node: "a", iface: "eth0"), b: IfaceRef(node: "r", iface: "Gi0/0")))
    try rt.handle(.connect(id: "2", a: IfaceRef(node: "r", iface: "Gi0/1"), b: IfaceRef(node: "s", iface: "eth0")))
    try rt.handle(.setIpv6(node: "r", iface: "Gi0/0", config: Ipv6Config(address: "2001:db8:1::1/64")))
    try rt.handle(.setIpv6(node: "r", iface: "Gi0/1", config: Ipv6Config(address: "2001:db8:2::1/64")))
    try rt.handle(.setIpv6Routing(node: "r", on: true))
    try rt.handle(.setIpv6(node: "a", iface: "eth0", config: Ipv6Config(autoconfig: true)))
    try rt.handle(.setIpv6(node: "s", iface: "eth0", config: Ipv6Config(address: "2001:db8:2::53/64")))
    try rt.handle(.setSink(node: "s", on: true))
    return rt
}

@Suite struct RuntimeIpv6ServicesTests {
    @Test func tcpConnectionsShowIpv6EndsInBrackets() throws {
        let rt = try lab()
        runFor(rt, ms: 3000)
        try rt.handle(.trafficTcp(node: "a", target: "2001:db8:2::53", bytes: 1_000_000_000))
        runFor(rt, ms: 200)
        let s = rt.snapshot()
        let row = s.nodes[0].tcp.first
        #expect(row?.local.hasPrefix("[2001:db8:1::ff:fe00:1]:") == true && row?.remote == "[2001:db8:2::53]:9" && row?.state == "ESTABLISHED")
        #expect(s.nodes[2].tcp.first == TcpRow(local: "0.0.0.0:9", remote: "0.0.0.0:*", state: "LISTEN"))
        #expect(s.apps[0].title == "iperf3 -c 2001:db8:2::53 -p 9 -n 1000000000")
    }
}
```

(`TcpRow` has a public memberwise init only inside the module; the test imports `@testable`.)

- [ ] **Step 2: Run.** `scripts/test.sh --filter Ipv6ServicesTests` → FAIL: `Invalid IPv4 address: "2001:db8:2::53"` from the flows.

- [ ] **Step 3: Implement.**

`PDU.swift`: after `TRAFFIC_DATAGRAM`:

```swift
/// The same over IPv6, whose header is 20 B longer: the packet stays at 1498 B (spec M9 §10).
let TRAFFIC_DATAGRAM6 = 1450
```

`TrafficData` gains, after `sentAt`, `/// The payload's size: smaller over IPv6.` `var bytes = TRAFFIC_DATAGRAM`; `UdpPayload.size`: `case .traffic(let d): d.bytes`. `EventViews.udpLayer`: `case .traffic(let d): "\(d.bytes) B (generatore di traffico, seq \(d.seq))"`.

`IpNode.swift`, after the other `sendUdp`s:

```swift
    /// UDP over either stack, from `src` if given. False without a route.
    @discardableResult
    func sendUdp(_ dst: IpAddr, srcPort: UInt16, dstPort: UInt16, payload: UdpPayload, src: IpAddr? = nil) -> Bool {
        let u = makeUdp(srcPort: srcPort, dstPort: dstPort, payload: payload)
        switch (dst, src) {
        case let (.v4(d), .v4(s)?): return sendPacket(d, .udp(u), src: s)
        case let (.v4(d), nil): return sendPacket(d, .udp(u))
        case let (.v6(d), .v6(s)?): return v6.send(d, .udp(u), src: s)
        case let (.v6(d), nil): return v6.send(d, .udp(u))
        default: return false // a source of the other version
        }
    }
```

`Traffic.swift`:

```swift
/// A target as typed: an IPv4 or IPv6 address, or nil for a host name. No link-local or multicast IPv6 targets, as for ping.
private func literalAddr(_ target: String) throws -> IpAddr? {
    if let a = try ipv6Target(target, tool: "Traffic") { return .v6(a) }
    return try literalIp(target).map(IpAddr.v4)
}
```

- `TcpFlow.init` and `UdpFlow.init`: `let literal = try literalAddr(target)`.
- `TcpFlow.resolved`: `return begin(.v4(first))` (Task 4 makes it `begin(first)`); `begin(_ ip: IpAddr)` with `"Connecting to host \(ip.text), port \(PORT_DISCARD)"` and `node.tcp.connect(to: ip, …)`; `update` uses `c.localIp.text` and `c.remoteIp.text`.
- `UdpFlow`: `private let interval: Int` and `private let count: Int` become `private var interval = 0`, `private var count = 0`; add `private let bitsPerSecond: Double`, `/// The datagram's payload: 1450 B over IPv6.` `private var datagram = TRAFFIC_DATAGRAM`; `private var dst: IpAddr = .v4(0)`. In `init` store `self.bitsPerSecond = bitsPerSecond` and drop the `interval =`/`count =` lines (moved to `begin`). `resolved`: `begin(.v4(first))`. `begin`:
  ```swift
      private func begin(_ ip: IpAddr) {
          dst = ip
          if case .v6 = ip { datagram = TRAFFIC_DATAGRAM6 }
          interval = Int((Double(datagram * 8) * Double(S) / bitsPerSecond).rounded())
          count = (seconds * S + interval - 1) / interval
          startedAt = node.sim.now
          result.lines = ["Connecting to host \(ip.text), port \(PORT_DISCARD)"]
          guard let src = node.source(for: ip) else {
              result.lines.append("iperf3: error - unable to connect to server: Network is unreachable")
              return finish()
          }
          result.lines.append("[  1] local \(src.text) port \(srcPort) connected to \(ip.text) port \(PORT_DISCARD)")
          … (the rest unchanged)
      }
  ```
  `send`: `node.sendUdp(dst, srcPort: srcPort, dstPort: PORT_DISCARD, payload: .traffic(TrafficData(flow: flow, seq: seq, sentAt: node.sim.now, bytes: datagram)))`; `sample` and `report`: `received * datagram`.

`Runtime.swift`, `tcpRows`:

```swift
    /// netstat -ant: listening ports, then connections in the order they were opened; an IPv6 end is "[address]:port" (spec M9 §10).
    private func tcpRows(_ n: IpNode) -> [TcpRow] {
        let end = { (a: IpAddr, port: UInt16) -> String in if case .v6 = a { "[\(a.text)]:\(port)" } else { "\(a.text):\(port)" } }
        return n.tcp.listening.map { TcpRow(local: "0.0.0.0:\($0)", remote: "0.0.0.0:*", state: "LISTEN") }
            + n.tcp.connections.map { TcpRow(local: end($0.localIp, $0.localPort), remote: end($0.remoteIp, $0.remotePort), state: $0.state.rawValue) }
    }
```

- [ ] **Step 4: Run.** Both suites PASS; full suite → 391; `swift build` builds.
- [ ] **Step 5: Commit** `feat(engine): the traffic generator over IPv6, TCP connections show [address]:port`.

---

### Task 4: Engine — DNS AAAA, the resolver's choice of address, nslookup A and AAAA

**Files:**
- Modify: `Sources/PacEngine/PDU.swift` (`DNS_TYPE_*`, `dnsTypeName`, `DnsAnswer`, `DnsMessage.type/size/address`)
- Modify: `Sources/PacEngine/L3/Dns.swift`
- Modify: `Sources/PacEngine/L3/IpNode.swift` (`effectiveNameServer: IpAddr?`)
- Modify: `Sources/PacEngine/L3/Ipv6.swift` (`hasGlobal`)
- Modify: `Sources/PacEngine/Apps/NsLookup.swift`, `Ping.swift`, `Traceroute.swift`, `Traffic.swift` (`resolved`)
- Modify: `Sources/PacEngine/Runtime/EventViews.swift` (DNS over IPv6, AAAA), `Runtime.swift` (records and cache rows)
- Test: `Tests/PacEngineTests/Ipv6ServicesTests.swift`

**Interfaces:**
- Consumes: Task 2 `IpAddr`, `bindUdp(_:both:)`; Task 3 `sendUdp(_: IpAddr…)`.
- Produces: `DNS_TYPE_A`, `DNS_TYPE_AAAA`, `dnsTypeName(_:)`; `DnsMessage.type`, `DnsMessage.address(_:) -> IpAddr`; `DnsAnswer.addr: UInt128`; `DnsEntry.addr: IpAddr`; `Resolution.found([IpAddr])`; `DnsCacheEntry.type`; `Resolver.lookup(_:server: IpAddr, type: UInt16 = DNS_TYPE_A, useCache:_:)`; `IpNode.effectiveNameServer: IpAddr?`; `Ipv6.hasGlobal`.

- [ ] **Step 1: Write the failing tests.** In `Ipv6ServicesTests.swift`, above the suite:

```swift
/// srv1.lab has both records, the others one each; SRV's IPv4 address is 10.0.2.10.
private let records = [
    DnsRecord(name: "srv1.lab", ip: "2001:db8:2::53"),
    DnsRecord(name: "srv1.lab", ip: "10.0.2.10"),
    DnsRecord(name: "v4only.lab", ip: "10.0.2.10"),
    DnsRecord(name: "v6only.lab", ip: "2001:db8:2::53"),
]

/// The types of the DNS queries a node sent, over either stack, in order.
private func queries(_ sim: Sim, from node: String) -> [UInt16] {
    sim.log.all.compactMap { e in
        guard e.kind == .tx, e.node == node else { return nil }
        var u: UdpDatagram?
        if case .ipv4(let p)? = e.frame?.payload, case .udp(let d) = p.payload { u = d }
        if case .ipv6(let p)? = e.frame?.payload, case .udp(let d) = p.payload { u = d }
        guard case .dns(let m)? = u?.payload, !m.response else { return nil }
        return m.type
    }
}
```

In the suite:

```swift
    @Test func aaaaQuestionsAndAnswersHaveTheirWireSizesAndLayers() throws {
        let q = DnsMessage(id: 1, response: false, name: "srv1.lab", type: DNS_TYPE_AAAA)
        #expect(q.size == 26) // header 12 + name 10 + type/class 4
        let r = DnsMessage(id: 1, response: true, authoritative: true, name: "srv1.lab", answers: [DnsAnswer(ttl: 3600, addr: SRV)], type: DNS_TYPE_AAAA)
        #expect(r.size == 54) // + 28: pointer, type, class, TTL, length, 16 B of address
        let p = makeIpv6(src: SRV, dst: try parseIp6(PC), hopLimit: 64, payload: .udp(makeUdp(srcPort: 53, dstPort: 40000, payload: .dns(r))))
        let e = SimEvent(time: 0, kind: .tx, node: "S", iface: "eth0", frame: EthernetFrame(
            id: 1, src: "02:00:00:00:00:02", dst: "02:00:00:00:00:04", etherType: ETHERTYPE_IPV6, payload: .ipv6(p)))
        #expect(eventView(e).proto == .dns && eventView(e).bytes == 116)
        #expect(eventView(e).info == "DNS Risposta 0x0001 AAAA srv1.lab → 2001:db8:2::53 · 2001:db8:2::53 → \(PC)")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv6", "UDP", "DNS"])
        #expect(layers[3].fields.contains(PduField(name: "Domanda", value: "srv1.lab tipo AAAA, classe IN")))
        #expect(layers[3].fields.contains(PduField(name: "Risposta 1", value: "srv1.lab AAAA 2001:db8:2::53, TTL 3600 s")))
    }

    @Test func theServerAnswersAaaaOnBothStacksAndNslookupShowsAAndAaaa() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureDnsServer(records)
        pc.nameServer = try parseIp("10.0.2.10")
        // One at a time at first: ARP queues at most 3 packets for the gateway.
        let both = try NsLookup(node: pc, name: "srv1.lab")
        sim.run(1 * S)
        let v4 = try NsLookup(node: pc, name: "v4only.lab")
        let v6 = try NsLookup(node: pc, name: "v6only.lab")
        sim.run(1 * S)
        let missing = try NsLookup(node: pc, name: "nope.lab")
        sim.run(1 * S)
        #expect(both.result.lines == ["Server:\t\t10.0.2.10", "Address:\t10.0.2.10#53", "",
                                     "Name:\tsrv1.lab", "Address: 10.0.2.10", "Name:\tsrv1.lab", "Address: 2001:db8:2::53", ""])
        #expect(Array(v4.result.lines.suffix(3)) == ["Name:\tv4only.lab", "Address: 10.0.2.10", ""]) // the AAAA got NODATA
        #expect(Array(v6.result.lines.suffix(3)) == ["Name:\tv6only.lab", "Address: 2001:db8:2::53", ""])
        #expect(Array(missing.result.lines.suffix(2)) == ["** server can't find nope.lab: NXDOMAIN", ""])
        #expect(queries(sim, from: "H1") == [DNS_TYPE_A, DNS_TYPE_AAAA, DNS_TYPE_A, DNS_TYPE_A, DNS_TYPE_AAAA, DNS_TYPE_AAAA, DNS_TYPE_A])
        // Over IPv6 the server answers from the address it was asked.
        var answers: [Resolution] = []
        pc.resolver.lookup("srv1.lab", server: .v6(SRV), type: DNS_TYPE_AAAA, useCache: false) { answers.append($0) }
        sim.run(1 * S)
        #expect(answers == [.found([.v6(SRV)])])
        expectError("Record srv1.lab AAAA 2001:db8:2::53 already exists") {
            try srv.configureDnsServer(records + [DnsRecord(name: "SRV1.lab", ip: "2001:DB8:2:0::53")])
        }
        expectError("Invalid IPv6 address") { try srv.configureDnsServer([DnsRecord(name: "a.lab", ip: "2001:db8::zz")]) }
    }

    @Test func namesResolveToTheAaaaOnlyWhenTheDeviceHasAGlobalIpv6Address() throws {
        let (sim, pc, srv, _) = try lab()
        try srv.configureDnsServer(records)
        pc.nameServer = try parseIp("10.0.2.10")
        let ping6 = try Ping(node: pc, target: "srv1.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping6.result.lines.first == "PING srv1.lab(2001:db8:2::53) 56 data bytes")
        #expect(ping6.result.replies.map(\.ttl) == [63])
        #expect(queries(sim, from: "H1") == [DNS_TYPE_A, DNS_TYPE_AAAA]) // back to back, like glibc
        #expect(pc.resolver.entries().map(\.type) == [DNS_TYPE_A, DNS_TYPE_AAAA])
        let ping4 = try Ping(node: pc, target: "v4only.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping4.result.lines.first == "PING v4only.lab (10.0.2.10) 56(84) bytes of data.")
        // Without a global IPv6 address only the A is asked, as before M9b.
        try pc.v6.configure("eth0", nil)
        let trace = try Traceroute(node: pc, target: "v6only.lab")
        sim.run(1 * S)
        #expect(trace.result.lines.first == "v6only.lab: Name or service not known")
        #expect(queries(sim, from: "H1").suffix(1) == [DNS_TYPE_A] && queries(sim, from: "H1").count == 5)
    }
```

- [ ] **Step 2: Run.** → build error `extra argument 'type' in call`.

- [ ] **Step 3: Implement.**

`PDU.swift`, after `DNS_NXDOMAIN`:

```swift
/// DNS record types (RFC 1035 §3.2.2, RFC 3596 §2.1).
let DNS_TYPE_A: UInt16 = 1
let DNS_TYPE_AAAA: UInt16 = 28

func dnsTypeName(_ type: UInt16) -> String {
    type == DNS_TYPE_AAAA ? "AAAA" : "A"
}
```

`DnsAnswer.addr`: `/// The record's data: an A's 32 bits or an AAAA's 128, as the message's `type` says.` `var addr: UInt128`. `DnsMessage`: doc `/// One-question DNS message for an A or AAAA record (class IN); answers repeat the question name.`; after `answers` add `var type = DNS_TYPE_A`; `size` doc `/// Header 12 B + question (labels + type + class) + answers (name as a 2-byte pointer, type, class, TTL, length, then 4 B of address for an A, 16 for an AAAA: 16 or 28 B).` and body `12 + name.split(separator: ".").reduce(1) { $0 + 1 + $1.utf8.count } + 4 + (type == DNS_TYPE_AAAA ? 28 : 16) * answers.count`; then

```swift
    /// An answer's address, read as the question's type.
    func address(_ a: DnsAnswer) -> IpAddr {
        type == DNS_TYPE_AAAA ? .v6(a.addr) : .v4(UInt32(truncatingIfNeeded: a.addr))
    }
```

`Dns.swift`:
- `DnsEntry.addr: IpAddr`; `parseDnsRecord` doc `/// An A record, or an AAAA when the address is IPv6 (spec M9 §10).`, address line:
  ```swift
      let text = r.ip.trimmingCharacters(in: .whitespaces)
      let addr: IpAddr = text.contains(":") ? .v6(try parseIp6(text)) : .v4(try parseIp(text))
  ```
- helpers:
  ```swift
  /// The record type an address answers.
  private func recordType(_ a: IpAddr) -> UInt16 {
      if case .v6 = a { DNS_TYPE_AAAA } else { DNS_TYPE_A }
  }

  /// The address as answer data.
  private func rdata(_ a: IpAddr) -> UInt128 {
      switch a {
      case .v4(let v): UInt128(v)
      case .v6(let v): v
      }
  }
  ```
- `DnsServer`: doc `/// Authoritative-only server for A and AAAA records on UDP 53 of both stacks (no recursion): NXDOMAIN for unknown names, no answers (NODATA, RFC 2308 §2.2) for a known name without records of the type asked (spec M9 §10).`; bind with `try node.bindUdp(PORT_DNS, both: { [weak self] client, server, u in if case .dns(let m) = u.payload { self?.answer(m, to: client, from: server, port: u.srcPort) } })`; `answer(_ q: DnsMessage, to client: IpAddr, from server: IpAddr, port: UInt16)`:
  ```swift
          guard !q.response else { return }
          let named = records.filter { $0.name == q.name.lowercased() }
          let hits = named.filter { recordType($0.addr) == q.type }
          let reply = DnsMessage(id: q.id, response: true, authoritative: true, recursionDesired: q.recursionDesired,
                                 rcode: named.isEmpty ? DNS_NXDOMAIN : 0, name: q.name,
                                 answers: hits.map { DnsAnswer(ttl: UInt32($0.ttl), addr: rdata($0.addr)) }, type: q.type)
          node.sendUdp(client, srcPort: PORT_DNS, dstPort: port, payload: .dns(reply), src: server)
  ```
- `configureDnsServer`: doc `A and AAAA records`; duplicate message `"Record \(e.name) \(dnsTypeName(recordType(e.addr))) \(e.addr.text) already exists"`.
- `Resolution.found([IpAddr])`; `DnsCacheEntry` gains `let type: UInt16` after `name` and `addrs: [IpAddr]`; `DnsQuery` gains `let type: UInt16` and `server: IpAddr` (init accordingly).
- `Resolver.resolve`:
  ```swift
      /// getaddrinfo with AI_ADDRCONFIG (spec M9 §10): the A, and the AAAA too when the device has a usable global IPv6 address, both
      /// asked at once like glibc; IPv6 addresses come first (RFC 6724 §6). Each type comes from the cache or the configured name
      /// server. `done` runs exactly once, possibly right away.
      func resolve(_ name: String, _ done: @escaping (Resolution) -> Void) {
          cache.removeAll { $0.expiresAt <= node.sim.now }
          let types = node.v6.hasGlobal ? [DNS_TYPE_A, DNS_TYPE_AAAA] : [DNS_TYPE_A]
          var answers: [UInt16: Resolution] = [:]
          for type in types {
              let collect = { (r: Resolution) in
                  answers[type] = r
                  if answers.count == types.count { done(merged(types.reversed().compactMap { answers[$0] })) }
              }
              if let hit = cache.first(where: { $0.name == name && $0.type == type }) {
                  collect(.found(hit.addrs))
              } else if let server = node.effectiveNameServer {
                  lookup(name, server: server, type: type, useCache: true, collect)
              } else {
                  collect(.failed)
              }
          }
      }
  ```
  and the file-level helper:
  ```swift
  /// getaddrinfo's answer from one answer per type: every address, else "not found" unless a query failed.
  private func merged(_ results: [Resolution]) -> Resolution {
      let addrs = results.flatMap { if case .found(let a) = $0 { a } else { [] } }
      if !addrs.isEmpty { return .found(addrs) }
      return results.contains(.failed) ? .failed : .nxdomain
  }
  ```
- `lookup(_ name: String, server: IpAddr, type: UInt16 = DNS_TYPE_A, useCache: Bool, _ done:)`: doc gains `for one record type; a name without records of the type answers .found([]) (NODATA)`; the bind is `node.bindUdp(q.port, both: { [weak self, weak q] src, _, u in if let self, let q, case .dns(let m) = u.payload, src == q.server, u.srcPort == PORT_DNS { self.answer(q, m) } })`.
- `ask`: `node.sendUdp(q.server, srcPort: q.port, dstPort: PORT_DNS, payload: .dns(DnsMessage(id: q.id, response: false, name: q.name, type: q.type)))`.
- `answer`:
  ```swift
          guard !q.finished, m.response, m.id == q.id, m.name == q.name, m.type == q.type else { return }
          guard m.rcode == 0 else { return finish(q, .nxdomain) }
          let addrs = m.answers.map(m.address)
          if q.useCache, !addrs.isEmpty, let ttl = m.answers.map(\.ttl).min(), ttl > 0 {
              cache.removeAll { $0.name == q.name && $0.type == q.type }
              cache.append(DnsCacheEntry(name: q.name, type: q.type, addrs: addrs, expiresAt: node.sim.now + Int(ttl) * S))
          }
          finish(q, .found(addrs)) // empty: NODATA
  ```

`IpNode.effectiveNameServer`: `var effectiveNameServer: IpAddr? { (nameServer ?? learnedNameServer).map(IpAddr.v4) }` (Task 5 adds RDNSS).

`Ipv6.swift`, after `owns`:

```swift
    /// A usable global address on any interface: the resolver then asks for AAAA records too (spec M9 §10).
    var hasGlobal: Bool {
        node.interfaces.contains { $0.v6?.addrs.contains { $0.origin != .linkLocal && $0.state == .preferred } == true }
    }
```

`NsLookup.swift`:

```swift
/// BIND-style `nslookup name`: asks the configured server directly (no cache) for the A, then the AAAA when the device has IPv6 on
/// (spec M9 §10), and prints the answers.
// ponytail: no PTR (reverse) lookups
final class NsLookup {
    private(set) var result = NsLookupResult()
    private let node: IpNode
    private let host: String
    private let server: IpAddr
    private var types: [UInt16]
    private var found = false

    init(node: IpNode, name: String) throws {
        guard let host = normalizeHostName(name) else { throw EngineError("Invalid host name: \"\(name)\"") }
        guard let server = node.effectiveNameServer else { throw EngineError("\(node.name) has no DNS server configured") }
        self.node = node
        self.host = host
        self.server = server
        types = node.interfaces.contains { $0.v6 != nil } ? [DNS_TYPE_A, DNS_TYPE_AAAA] : [DNS_TYPE_A]
        result.lines = ["Server:\t\t\(server.text)", "Address:\t\(server.text)#53", ""]
        ask()
    }

    func stop() {
        result.done = true
    }

    private func ask() {
        node.resolver.lookup(host, server: server, type: types.removeFirst(), useCache: false) { [weak self] r in self?.answered(r) }
    }

    private func answered(_ r: Resolution) {
        guard !result.done else { return }
        switch r {
        case .found(let addrs):
            for a in addrs { result.lines += ["Name:\t\(host)", "Address: \(a.text)"] }
            found = found || !addrs.isEmpty
            if !types.isEmpty { return ask() }
            if !found { result.lines.append("*** Can't find \(host): No answer") }
        case .nxdomain:
            result.lines.append("** server can't find \(host): NXDOMAIN")
        case .failed:
            result.lines.append(";; connection timed out; no servers could be reached")
        }
        result.lines.append("")
        result.done = true
    }
}
```

`Ping.resolved` and `Traceroute.resolved`:

```swift
        if case .found(let addrs) = r, let first = addrs.first {
            switch first {
            case .v4(let a): return begin(a)
            case .v6(let a): return begin6(a)
            }
        }
```

`Traffic.swift`: both `resolved` call `begin(first)`.

`EventViews.swift`:
- `dnsSummary`:
  ```swift
  private func dnsSummary(_ m: DnsMessage) -> String {
      let id = hex(Int(m.id), digits: 4)
      let type = dnsTypeName(m.type)
      if !m.response { return "Query \(id) \(type) \(m.name)" }
      if m.rcode == DNS_NXDOMAIN { return "Risposta \(id) NXDOMAIN \(m.name)" }
      if m.answers.isEmpty { return "Risposta \(id) \(type) \(m.name) senza record" }
      return "Risposta \(id) \(type) \(m.name) → " + m.answers.map { m.address($0).text }.joined(separator: ", ")
  }
  ```
- `dnsLayer`: `field("Domanda", "\(m.name) tipo \(dnsTypeName(m.type)), classe IN")` and `field("Risposta \(i + 1)", "\(m.name) \(dnsTypeName(m.type)) \(m.address(a).text), TTL \(a.ttl) s")`.
- `proto(of p: Ipv6Packet)`: `case .udp(let u): if case .dns = u.payload { .dns } else { .udp }`.
- `describe(_ p: Ipv6Packet)`: `case .udp(let u): if case .dns(let m) = u.payload { "DNS \(dnsSummary(m))" } else { "UDP \(u.srcPort) → \(u.dstPort) hlim=\(p.hopLimit)" }`.
- `ipv6Layers`: `case .udp(let u): if case .dns(let m) = u.payload { return [ip, udpLayer(u), dnsLayer(m)] }; return [ip, udpLayer(u)]` (two lines).

`Runtime.swift` build: `dnsRecords: … DnsRecord(name: $0.name, ip: $0.addr.text, ttl: $0.ttl)`, `dnsCache: … DnsCacheRow(name: e.name, ip: $0.text, …)`.

- [ ] **Step 4: Run.** `Ipv6ServicesTests` PASS; `DnsTests`, `DhcpDnsPduTests`, `RuntimeServicesTests`, `CloudTests` unchanged and PASS; full suite → 394.
- [ ] **Step 5: Commit** `feat(engine): DNS AAAA on both stacks, AAAA before A for devices with a global IPv6 address, nslookup shows both`.

---

### Task 5: Engine and project files — RDNSS

**Files:**
- Modify: `Sources/PacEngine/Ipv6Pdu.swift` (`RDNSS_LIFETIME`, `RouterAdvert.dns/dnsLifetime`, size, serialisation)
- Modify: `Sources/PacEngine/L3/Ipv6.swift` (`rdnss`, `learnedDns`, `dnsServer`)
- Modify: `Sources/PacEngine/L3/IpNode.swift` (`effectiveNameServer`)
- Modify: `Sources/PacEngine/Runtime/EventViews.swift` (option 25 in the inspector)
- Modify: `Sources/PacEngine/Runtime/Protocol.swift` (`Command.setRdnss`, `NodeView.rdnss`, `TopologyNode.rdnss`)
- Modify: `Sources/PacEngine/Runtime/Runtime.swift` (command, view, load)
- Modify: `Sources/PacKit/Topology+Helpers.swift` (`makeTopology`)
- Test: `Tests/PacEngineTests/Ipv6ServicesTests.swift`, `Tests/PacEngineTests/RuntimeIpv6ServicesTests.swift`, `Tests/PacKitTests/Ipv6ServicesEditorTests.swift` (create)

**Interfaces:**
- Consumes: Task 4 `effectiveNameServer: IpAddr?`.
- Produces: `RDNSS_LIFETIME: UInt32 = 600`; `RouterAdvert.dns: UInt128?`, `.dnsLifetime: UInt32`; `Ipv6.rdnss: UInt128?` (router setting), `Ipv6.dnsServer: UInt128?` (learned); `Command.setRdnss(node: String, server: String?)`; `NodeView.rdnss: String?`; `TopologyNode.rdnss: String?` (consumed by Task 8's UI).

- [ ] **Step 1: Write the failing tests.** In `Ipv6ServicesTests.swift`, the `lab` helper applies `rdnss` before running: after `r1.v6.setRouting(true)` add `if let rdnss { r1.v6.rdnss = try parseIp6(rdnss) }`. In the suite:

```swift
    @Test func routersAdvertiseTheirDnsServerAndHostsUseItLast() throws {
        let (sim, pc, srv, r1) = try lab(rdnss: "2001:db8:2::53")
        try srv.configureDnsServer(records)
        #expect(pc.v6.dnsServer == SRV && pc.effectiveNameServer == .v6(SRV))
        // The RA's RDNSS option: after the prefix, 24 B, lifetime 600 s.
        let ras = sim.log.all.compactMap { e -> Ipv6Packet? in
            guard e.kind == .tx, e.node == "R1", e.iface == "Gi0/0", case .ipv6(let p)? = e.frame?.payload, case .ndp(let n) = p.payload,
                  n.type == ND_RA else { return nil }
            return p
        }
        #expect(ras.map(\.size) == [128]) // the RA of 1 s: 40 + 16 + SLLA 8 + MTU 8 + one prefix 32 + RDNSS 24
        #expect(Array(serializePayload(ras[0]).suffix(24)) == [25, 3, 0, 0, 0, 0, 0x02, 0x58] + bytes16(SRV))
        let ping = try Ping(node: pc, target: "srv1.lab", options: PingOptions(count: 1))
        sim.run(2 * S)
        #expect(ping.result.lines.first == "PING srv1.lab(2001:db8:2::53) 56 data bytes" && ping.result.received == 1)
        #expect(sim.log.all.contains { e in
            guard e.kind == .tx, e.node == "H1", case .ipv6(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .dns = u.payload else { return false }
            return p.dst == SRV
        })
        // A server typed by hand comes first.
        pc.nameServer = try parseIp("10.0.2.10")
        #expect(pc.effectiveNameServer == .v4(try parseIp("10.0.2.10")))
        pc.nameServer = nil
        // The router stops advertising it: it lasts 600 s from the last RA that carried it (the answer to the RSs, at 4 s).
        r1.v6.rdnss = nil
        sim.run(604 * S - 1 - sim.now)
        #expect(pc.v6.dnsServer == SRV)
        sim.run(1 * S)
        #expect(pc.v6.dnsServer == nil && pc.effectiveNameServer == nil)
        // Lifetime 0 withdraws it at once.
        let ll = linkLocal("02:00:00:00:00:03")
        let ra = { (lifetime: UInt32) in makeIpv6(src: ll, dst: ALL_NODES, hopLimit: 255, payload: .ndp(NdpMessage(body: .ra(RouterAdvert(
            slla: "02:00:00:00:00:03", prefixes: [], dns: SRV, dnsLifetime: lifetime))))) }
        pc.v6.input(ra(600), on: try pc.iface("eth0"))
        #expect(pc.v6.dnsServer == SRV)
        pc.v6.input(ra(0), on: try pc.iface("eth0"))
        #expect(pc.v6.dnsServer == nil)
    }
```

In `RuntimeIpv6ServicesTests`:

```swift
    @Test func theAdvertisedServerIsShownSavedAndLoaded() throws {
        let rt = try lab()
        try rt.handle(.setRdnss(node: "r", server: " 2001:db8:2::53 "))
        runFor(rt, ms: 3000)
        let s = rt.snapshot()
        #expect(s.nodes[1].rdnss == "2001:db8:2::53" && s.nodes[0].learnedNameServer == "2001:db8:2::53" && s.nodes[0].nameServer == nil)
        expectError("PC1 cannot advertise a DNS server") { try rt.handle(.setRdnss(node: "a", server: "2001:db8:2::53")) }
        expectError("Invalid IPv6 address") { try rt.handle(.setRdnss(node: "r", server: "2001:db8::zz")) }
        let t = Topology(nodes: [TopologyNode(id: "r", kind: .router, name: "R1", pos: Pos(x: 0, y: 0),
                                              ifaces: (0...3).map { TopologyIface(name: "Gi0/\($0)", cidr: nil) }, routes: [],
                                              ipv6Routing: true, rdnss: "2001:db8:2::53")])
        let copy = try JSONDecoder().decode(Topology.self, from: try JSONEncoder().encode(t))
        #expect(copy == t)
        try rt.handle(.load(copy))
        #expect(rt.snapshot().nodes[0].rdnss == "2001:db8:2::53")
        try rt.handle(.setRdnss(node: "r", server: nil))
        #expect(rt.snapshot().nodes[0].rdnss == nil)
        let old = #"{"id":"r","kind":"router","name":"R1","pos":{"x":0,"y":0},"ifaces":[],"routes":[],"ipv6Routing":true}"#
        #expect(try JSONDecoder().decode(TopologyNode.self, from: Data(old.utf8)).rdnss == nil) // an M9a file
    }
```

Create `Tests/PacKitTests/Ipv6ServicesEditorTests.swift`:

```swift
import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct Ipv6ServicesEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func theAdvertisedServerIsSavedAndUndoneButNotCopied() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        let r = node("R1").id
        await editor.edit(.setRdnss(node: r, server: "2001:db8:2::53"))
        #expect(editor.current.nodes[0].rdnss == "2001:db8:2::53")
        await editor.duplicate([r])
        #expect(node("R2").rdnss == nil) // like ipv6 unicast-routing (spec M9 §10)
        await editor.undo()
        await editor.undo()
        #expect(editor.current.nodes[0].rdnss == nil)
    }
}
```

- [ ] **Step 2: Run.** → build error `extra argument 'dns' in call` / `no member 'setRdnss'`.

- [ ] **Step 3: Implement.**

`Ipv6Pdu.swift`: after `RA_MTU`:

```swift
/// RDNSS (RFC 8106 §5.1): how long hosts may use the advertised DNS server, the minimum of 3 × MaxRtrAdvInterval (200 s, spec M9 §10).
let RDNSS_LIFETIME: UInt32 = 600
```

`RouterAdvert` doc ends `…; RDNSS when the router has a DNS server to advertise (spec M9 §10).` and gains, after `prefixes`:

```swift
    /// RDNSS (RFC 8106): one DNS server, and how long it may be used.
    var dns: UInt128? = nil
    var dnsLifetime = RDNSS_LIFETIME
```

`NdpMessage.size` doc: `/// Header and fields, plus 8 B per link-layer address option, 8 B of MTU, 32 B per prefix and 24 B of RDNSS.`; `case .ra(let ra): 32 + 32 * ra.prefixes.count + (ra.dns == nil ? 0 : 24)`. `serialize`, after the prefixes loop:

```swift
        if let dns = ra.dns {
            b += [25, 3, 0, 0] + u32(ra.dnsLifetime) + bytes16(dns) // RDNSS, 3 × 8 B (RFC 8106 §5.1)
        }
```

`Ipv6.swift`:
- properties, after `statics`:
  ```swift
      /// Routers: IOS `ipv6 nd ra dns server`, the DNS server every RA advertises (RDNSS, spec M9 §10).
      var rdnss: UInt128?
      /// Hosts: the DNS server the last RA advertised, until its lifetime ends (RFC 8106 §5.3.1).
      private var learnedDns: (addr: UInt128, iface: Interface, expiresAt: Int)?
  ```
- after `hasGlobal`:
  ```swift
      /// The DNS server learned from RAs while its lifetime lasts: the name server after the typed and the DHCP one (spec M9 §10).
      var dnsServer: UInt128? {
          learnedDns.flatMap { $0.expiresAt > now ? $0.addr : nil }
      }
  ```
- `configure`, in the `nil` branch after `defaults.removeAll …`: `if learnedDns?.iface === iface { learnedDns = nil }`.
- `receive`, `.ra` case, before `// SLAAC (RFC 4862 §5.5.3)…`:
  ```swift
              if let dns = ra.dns {
                  // RDNSS (RFC 8106 §5.3.1): the server for its lifetime; lifetime 0 withdraws it.
                  learnedDns = ra.dnsLifetime > 0 ? (dns, iface, now + Int(ra.dnsLifetime) * S) : learnedDns?.addr == dns ? nil : learnedDns
              }
  ```
- `advertise`: `RouterAdvert(lifetime: lifetime, slla: iface.mac, prefixes: prefixes, dns: rdnss)`.
- `reset`: after `defaults = []` add `learnedDns = nil`.

`IpNode.effectiveNameServer`: doc `/// Typed by hand, else from DHCP, else from RDNSS (spec M9 §10).` body `(nameServer ?? learnedNameServer).map(IpAddr.v4) ?? v6.dnsServer.map(IpAddr.v6)`.

`EventViews.ndpLayer`, after the prefixes loop: `if let dns = ra.dns { fields.append(field("Opzione 25", "RDNSS \(formatIp6(dns)), lifetime \(ra.dnsLifetime) s")) }`.

`Protocol.swift`:
- `Command`, after `setIpv6Routing`: `/// Routers: IOS `ipv6 nd ra dns server`, the DNS server their RAs advertise (RDNSS, spec M9 §10); nil clears it.` `case setRdnss(node: String, server: String?)`; `key`: `case .setRdnss: "setRdnss"`.
- `NodeView`, after `neighbors6`: `/// Routers: the DNS server their RAs advertise (RDNSS).` `public let rdnss: String?`; the doc of `learnedNameServer` becomes `/// Name server learned from DHCP, else from an RA (RDNSS).`
- `TopologyNode`: `/// Routers: the DNS server their RAs advertise (spec M9 §10).` `public var rdnss: String?`; init parameter `rdnss: String? = nil` after `ipv6Routing`, `self.rdnss = rdnss`; decoder `rdnss = try c.decodeIfPresent(String.self, forKey: .rdnss)`; its doc gains `, before M9b no `rdnss``.

`Runtime.swift`:
- `handle`, after `.setIpv6Routing`:
  ```swift
          case let .setRdnss(node, server):
              let n = try ipNode(node)
              guard server == nil || nodes[node]?.kind == .router else { throw EngineError("\(n.name) cannot advertise a DNS server") }
              let text = server?.trimmingCharacters(in: .whitespaces) ?? ""
              n.v6.rdnss = try text.isEmpty ? nil : parseIp6(text)
  ```
- `build`: `learnedNameServer: ip?.learnedNameServer.map(formatIp) ?? ip?.v6.dnsServer.map(formatIp6)`, and after `neighbors6:` `rdnss: ip?.v6.rdnss.map(formatIp6)`.
- `load`, after the `ipv6Routing` line: `if let server = n.rdnss { try next.handle(.setRdnss(node: n.id, server: server)) }`.

`Topology+Helpers.swift` `makeTopology`: `ipv6Routing: n.ipv6Routing, rdnss: n.rdnss)`.

- [ ] **Step 4: Run.** The three suites PASS; full suite → 397; `swift build` builds.
- [ ] **Step 5: Commit** `feat: routers advertise a DNS server in their RAs (RDNSS), hosts use it after the typed and the DHCP one`.

---

### Task 6: Engine — the firewall filters IPv6

**Files:**
- Modify: `Sources/PacEngine/PDU.swift` (`Endpoints<Addr>`)
- Modify: `Sources/PacEngine/Ipv6Pdu.swift` (`endpoints(_: Ipv6Packet)`, `quotedEndpoints6`)
- Modify: `Sources/PacEngine/L3/Nat.swift` (`add`'s parameter type)
- Modify: `Sources/PacEngine/L3/Firewall.swift`
- Modify: `Sources/PacEngine/L3/Ipv6.swift` (`input`, `send`, `admits`)
- Modify: `Tests/PacEngineTests/Ipv6Tests.swift` (`natAndTheFirewallLeaveIpv6Alone`: an IPv6 allow rule)
- Test: `Tests/PacEngineTests/Ipv6ServicesTests.swift`

**Interfaces:**
- Consumes: Task 2 TCP/UDP over IPv6; Task 3 `TcpFlow` to IPv6.
- Produces: `struct Endpoints<Addr: Equatable>`; `func endpoints(_ p: Ipv6Packet) -> Endpoints<UInt128>?`; `func quotedEndpoints6(_ m: IcmpMessage) -> Endpoints<UInt128>?`; `Firewall.admits(_ p: Ipv6Packet, from:to:)`, `Firewall.track(_ p: Ipv6Packet)`.

- [ ] **Step 1: Write the failing tests.** In `Ipv6ServicesTests.swift`, the `lab` helper installs the firewall before running: after `try srv.v6.configure…` add `if let firewall { r1.firewall = try Firewall(node: r1, config: firewall) }`. In the suite:

```swift
    @Test func anIpv6RuleStopsOnlyIpv6AndAnIcmpRuleCoversIcmpv6() throws {
        let deny6 = FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .any, src: "2001:db8:1::/64", dst: "any")
        let (sim, pc, srv, r1) = try lab(firewall: FirewallConfig(rules: [deny6]))
        try srv.configureSink(true)
        let ping6 = try Ping(node: pc, target: "2001:db8:2::53", options: PingOptions(count: 1, timeoutNs: 2 * S))
        let ping4 = try Ping(node: pc, target: "10.0.2.10", options: PingOptions(count: 1))
        sim.run(3 * S)
        #expect(ping6.result.received == 0 && ping4.result.received == 1 && drops(sim, .firewallRule) == 1) // the spec's M9b success
        let denyIcmp = FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .icmp, src: "any", dst: "any")
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [denyIcmp]))
        let echo = try Ping(node: pc, target: "2001:db8:2::53", options: PingOptions(count: 1, timeoutNs: 2 * S))
        let flow = try TcpFlow(node: pc, target: "2001:db8:2::53", bytes: 1000)
        sim.run(3 * S)
        #expect(echo.result.received == 0 && flow.result.lines.last == "iperf Done.")
        let mixed = FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .any, src: "10.0.1.0/24", dst: "2001:db8:2::/64")
        expectError("A rule cannot mix IPv4 and IPv6 addresses") { _ = try Firewall(node: r1, config: FirewallConfig(rules: [mixed])) }
        let bad = FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .any, src: "2001:db8::zz", dst: "any")
        expectError("Invalid IPv6 address") { _ = try Firewall(node: r1, config: FirewallConfig(rules: [bad])) }
    }

    @Test func ipv6FlowsAreTrackedAndNeighbourDiscoveryIsNeverFiltered() throws {
        let allow = { (proto: FirewallProto) in FirewallRule(iface: "Gi0/0", direction: .inbound, action: .allow, proto: proto, src: "any", dst: "any") }
        // Deny by default from t = 0: R1 learns no neighbour from the hosts' RSs, which it drops.
        let (sim, pc, srv, r1) = try lab(firewall: FirewallConfig(rules: [allow(.icmp), allow(.tcp), allow(.udp)], defaultAction: .deny))
        try srv.configureSink(true)
        var unreachable: [UInt8] = []
        pc.v6.onIcmp { _, m in if m.type == ICMP6_DEST_UNREACH { unreachable.append(m.code) } }
        let out = try Ping(node: pc, target: "2001:db8:2::53", options: PingOptions(count: 1))
        let flow = try TcpFlow(node: pc, target: "2001:db8:2::53", bytes: 10_000)
        let back = try Ping(node: srv, target: PC, options: PingOptions(count: 1, timeoutNs: 2 * S))
        let own = try Ping(node: r1, target: PC, options: PingOptions(count: 1)) // NS out, NA back in through the deny policy
        pc.v6.send(SRV, .udp(makeUdp(srcPort: 40000, dstPort: 5001, data: [1]))) // its Port Unreachable is related
        sim.run(3 * S)
        #expect(out.result.received == 1 && flow.result.lines.last == "iperf Done." && own.result.received == 1)
        #expect(back.result.received == 0)
        #expect(unreachable == [UNREACH6_PORT])
        let dropped = sim.log.all.filter { $0.reason == .firewallDefault }.compactMap { e -> UInt8? in
            guard case .ndp(let n)? = e.packet6?.payload else { return nil }
            return n.type
        }
        #expect(dropped.contains(ND_RS) && !dropped.contains(ND_NS) && !dropped.contains(ND_NA))
    }
```

In `Ipv6Tests.natAndTheFirewallLeaveIpv6Alone`, replace the firewall line with

```swift
        // M9b: the policy covers IPv6 too (spec M9 §10), so IPv6 needs its own rule; NAT still leaves it alone.
        let allow6 = FirewallRule(iface: "Gi0/0", direction: .inbound, action: .allow, proto: .any, src: "2001:db8:1::/64", dst: "any")
        r1.firewall = try Firewall(node: r1, config: FirewallConfig(rules: [allow6], defaultAction: .deny))
```

- [ ] **Step 2: Run.** `scripts/test.sh --filter Ipv6ServicesTests` → FAIL: `ping6.result.received == 1`, `Invalid IPv4 address: "2001:db8:1::"`.

- [ ] **Step 3: Implement.**

`PDU.swift`: `struct Endpoints<Addr: Equatable>: Equatable { var proto: UInt8; var src: Addr; var srcPort: UInt16; var dst: Addr; var dstPort: UInt16; var reversed … }` (doc adds `IPv4 for NAT and the firewall, IPv6 for the firewall (spec M9 §10).`); `func endpoints(_ p: Ipv4Packet) -> Endpoints<UInt32>?`; `func quotedEndpoints(_ m: IcmpMessage) -> Endpoints<UInt32>?`. `Nat.add(_ e: Endpoints<UInt32>, global: UInt32)`.

`Ipv6Pdu.swift`, at the end:

```swift
/// A packet's flow as the firewall sees it (spec M9 §10), like `endpoints` for IPv4: ICMPv6 echo uses its identifier as the
/// requester's port; errors and NDP have none.
func endpoints(_ p: Ipv6Packet) -> Endpoints<UInt128>? {
    switch p.payload {
    case .tcp(let t): Endpoints(proto: IPPROTO_TCP, src: p.src, srcPort: t.srcPort, dst: p.dst, dstPort: t.dstPort)
    case .udp(let u): Endpoints(proto: IPPROTO_UDP, src: p.src, srcPort: u.srcPort, dst: p.dst, dstPort: u.dstPort)
    case .icmp(let m) where m.type == ICMP6_ECHO_REQUEST: Endpoints(proto: IPPROTO_ICMPV6, src: p.src, srcPort: m.id, dst: p.dst, dstPort: 0)
    case .icmp(let m) where m.type == ICMP6_ECHO_REPLY: Endpoints(proto: IPPROTO_ICMPV6, src: p.src, srcPort: 0, dst: p.dst, dstPort: m.id)
    case .icmp, .ndp: nil
    }
}

/// The flow an ICMPv6 error is about, read from the IPv6 header and the first 8 bytes it quotes (RFC 4443 §2.4 c), as its sender
/// sent it.
func quotedEndpoints6(_ m: IcmpMessage) -> Endpoints<UInt128>? {
    let q = m.data
    guard m.type < 128, q.count >= 48 else { return nil }
    let addr = { (at: Int) in q[at..<at + 16].reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }
    let port = { (at: Int) in UInt16(q[at]) << 8 | UInt16(q[at + 1]) }
    switch q[6] {
    case IPPROTO_TCP, IPPROTO_UDP: return Endpoints(proto: q[6], src: addr(8), srcPort: port(40), dst: addr(24), dstPort: port(42))
    case IPPROTO_ICMPV6 where q[40] == ICMP6_ECHO_REQUEST: return Endpoints(proto: IPPROTO_ICMPV6, src: addr(8), srcPort: port(44), dst: addr(24), dstPort: 0)
    default: return nil
    }
}
```

`Firewall.swift`, the whole file:

```swift
import Foundation

/// A rule's address: "any" (both versions), or an IPv4 or IPv6 address (/32, /128) or prefix.
private enum Match {
    case any
    case v4(Cidr)
    case v6(Cidr6)
}

private func holds(_ m: Match, _ a: UInt32) -> Bool {
    switch m {
    case .any: true
    case .v4(let c): inSubnet(a, c.addr, c.prefix)
    case .v6: false
    }
}

private func holds(_ m: Match, _ a: UInt128) -> Bool {
    switch m {
    case .any: true
    case .v4: false
    case .v6(let c): inSubnet6(a, c.addr, c.prefix)
    }
}

private struct CompiledRule {
    let iface: String
    let out: Bool
    let allow: Bool
    /// The IPv4 protocol number; ICMP also matches ICMPv6 (spec M9 §10).
    let proto: UInt8?
    let src: Match
    let dst: Match
    let port: UInt16?

    func matches(_ p: Ipv4Packet, _ e: Endpoints<UInt32>?) -> Bool {
        (proto.map { $0 == p.proto } ?? true) && holds(src, p.src) && holds(dst, p.dst) && (port.map { $0 == e?.dstPort } ?? true)
    }

    func matches(_ p: Ipv6Packet, _ e: Endpoints<UInt128>?) -> Bool {
        (proto.map { ($0 == IPPROTO_ICMP ? IPPROTO_ICMPV6 : $0) == p.payload.nextHeader } ?? true) && holds(src, p.src) && holds(dst, p.dst)
            && (port.map { $0 == e?.dstPort } ?? true)
    }

    func on(_ inIface: Interface, _ outIface: Interface?) -> Bool {
        iface == (out ? outIface?.name : inIface.name)
    }
}

private func parseMatch(_ text: String) throws -> Match {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.lowercased() == "any" { return .any }
    if t.contains(":") { return .v6(t.contains("/") ? try parseCidr6(t) : Cidr6(addr: try parseIp6(t), prefix: 128)) }
    return .v4(t.contains("/") ? try parseCidr(t) : Cidr(addr: try parseIp(t), prefix: 32))
}

private func compile(_ r: FirewallRule, on node: IpNode) throws -> CompiledRule {
    … (unchanged up to the protocol)
    let (src, dst) = (try parseMatch(r.src), try parseMatch(r.dst))
    switch (src, dst) {
    case (.v4, .v6), (.v6, .v4): throw EngineError("A rule cannot mix IPv4 and IPv6 addresses")
    default: break
    }
    return CompiledRule(iface: r.iface, out: r.direction == .outbound, allow: r.action == .allow, proto: proto,
                        src: src, dst: dst, port: r.port.map { UInt16($0) })
}
```

The class doc gains: `IPv6 is filtered the same way with its own flows (spec M9 §10), except NS and NA, which always pass.` Body:

```swift
    private var flows: [(flow: Endpoints<UInt32>, expiresAt: Int)] = []
    /// The same for IPv6.
    private var flows6: [(flow: Endpoints<UInt128>, expiresAt: Int)] = []

    func reset() {
        flows = []
        flows6 = []
    }

    func admits(_ p: Ipv4Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
        let e = endpoints(p)
        let quoted: Endpoints<UInt32>? = if case .icmp(let m) = p.payload { quotedEndpoints(m) } else { nil }
        return decide(e, quoted, in: &flows, rules.first { $0.matches(p, e) && $0.on(inIface, outIface) }, inIface, outIface) {
            node.sim.emit(.drop, node: node.id, iface: $0.name, packet: p, reason: $1)
        }
    }

    /// The same decision for IPv6, except that NS and NA always pass, like IOS's implicit `permit icmp any any nd-ns` and `nd-na`:
    /// address resolution never breaks (spec M9 §10).
    func admits(_ p: Ipv6Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
        if case .ndp(let n) = p.payload, n.type == ND_NS || n.type == ND_NA { return true }
        let e = endpoints(p)
        let quoted: Endpoints<UInt128>? = if case .icmp(let m) = p.payload { quotedEndpoints6(m) } else { nil }
        return decide(e, quoted, in: &flows6, rules.first { $0.matches(p, e) && $0.on(inIface, outIface) }, inIface, outIface) {
            node.sim.emit(.drop, node: node.id, iface: $0.name, reason: $1, packet6: p)
        }
    }

    func track(_ p: Ipv4Packet) { guard let e = endpoints(p), !refreshed(e, in: &flows) else { return }; flows.append((e, node.sim.now + flowTimeout(e.proto))) }
    func track(_ p: Ipv6Packet) { …same with flows6 }

    /// A tracked flow, or an ICMP error quoting one, passes; otherwise the first rule on the packet's interface decides, then the
    /// policy. A packet let through records its flow; a refused one is handed to `drop` with the interface the rule names.
    private func decide<A: Equatable>(_ e: Endpoints<A>?, _ quoted: Endpoints<A>?, in flows: inout [(flow: Endpoints<A>, expiresAt: Int)],
                                      _ rule: CompiledRule?, _ inIface: Interface, _ outIface: Interface?,
                                      drop: (Interface, DropReason) -> Void) -> Bool {
        if refreshed(e, in: &flows) { return true }
        if let quoted, flows.contains(where: { $0.flow == quoted || $0.flow == quoted.reversed }) { return true }
        guard rule?.allow ?? (config.defaultAction == .allow) else {
            drop(rule?.out == true ? outIface ?? inIface : inIface, rule == nil ? .firewallDefault : .firewallRule)
            return false
        }
        if let e { flows.append((e, node.sim.now + flowTimeout(e.proto))) }
        return true
    }

    /// Forgets idle flows, then refreshes `e`'s in either direction; false when it is not tracked.
    private func refreshed<A: Equatable>(_ e: Endpoints<A>?, in flows: inout [(flow: Endpoints<A>, expiresAt: Int)]) -> Bool { …as before, on `flows` }
```

(`track` written out over several lines as before.)

`Ipv6.swift`:
- `input`: the group delivery becomes `if groups(iface).contains(p.dst) && admits(p, from: iface, to: nil) { deliver(p, on: iface) }`; own addresses `if owns(p.dst) { if admits(p, from: iface, to: nil) { deliver(p, on: iface) }; return }` (written on separate lines); after the route lookup:
  ```swift
          var next = p
          next.hopLimit -= 1
          guard admits(next, from: iface, to: hop.iface) else { return }
          output(next, via: hop)
  ```
- helper:
  ```swift
      /// The router's firewall (spec M9 §10), as `IpNode` asks it for IPv4.
      private func admits(_ p: Ipv6Packet, from inIface: Interface, to outIface: Interface?) -> Bool {
          node.firewall?.admits(p, from: inIface, to: outIface) ?? true
      }
  ```
- `send`: `let p = makeIpv6(…)`, `node.firewall?.track(p)` (its own packets are never filtered, their flows recorded), `output(p, via: hop)`.

- [ ] **Step 4: Run.** `Ipv6ServicesTests`, `Ipv6Tests`, `FirewallTests`, `NatTests`, `RuntimeNatFirewallTests` PASS; full suite → 399.
- [ ] **Step 5: Commit** `feat(engine): firewall rules for IPv6, ICMP rules cover ICMPv6, IPv6 flows tracked, NS and NA never filtered`.

---

### Task 7: UI — the static-route form says it takes IPv6 (deferred M9a Minor)

**Files:**
- Modify: `Sources/PacTrack/InspectorView.swift` (`RoutingTab`)
- Modify: `Sources/PacTrack/SelfTest.swift` (`ipv6Scenario`: an IPv6 static route before the routing image)

- [ ] **Step 1: Selftest first.** In `ipv6Scenario`, before `editor.select(.node(id("R1")))`:

```swift
        await editor.edit(.addRoute(node: id("R1"), cidr: "2001:db8:9::/64", nextHop: "2001:db8:2::99"))
        if !(editor.snapshot.nodes.first { $0.name == "R1" }?.routes.contains { $0.dest == "2001:db8:9::/64" && $0.isStatic } ?? false) {
            failures.append("R1 has no IPv6 static route")
        }
```

Run `scripts/selftest.sh build/selftest.png`; read `build/selftest-m9a-routing.png`: the form shows only "10.0.2.0/24" (the Minor), and check how the IPv6 row renders.

- [ ] **Step 2: Implement.** In `RoutingTab`, between the `HStack` of the two fields and `ErrorLine(editor: editor, key: routeKey)`:

```swift
                Text("Prefisso e next hop IPv4 o IPv6, es. 2001:db8:9::/64 via 2001:db8:1::2").font(Theme.small).foregroundStyle(Theme.muted)
```

If the image shows the IPv6 route row wrapping, give its `Text` `.lineLimit(1).minimumScaleFactor(0.75)` as the DNS records do.

- [ ] **Step 3: Verify.** `SELFTEST OK`; the image shows the hint on one or two lines and `2001:db8:9::/64 via 2001:db8:2::99` on one line. `scripts/test.sh` unchanged count.
- [ ] **Step 4: Commit** `fix(ui): the static-route form says it takes IPv6, the M9a routing image shows an IPv6 route`.

---

### Task 8: UI — RDNSS field, AAAA records, firewall copy, learned server; M9b selftest images

**Files:**
- Modify: `Sources/PacTrack/InspectorView.swift` (`RoutingTab` RDNSS field, host "Server DNS" placeholder)
- Modify: `Sources/PacTrack/ServicesTab.swift` (DNS records, firewall copy)
- Modify: `Sources/PacTrack/SelfTest.swift` (`ipv6ServicesScenario`, called from `scenario`)

**Interfaces:**
- Consumes: Task 5 `Command.setRdnss`, `NodeView.rdnss`, `NodeView.learnedNameServer`; Tasks 2–6 engine behaviour.

- [ ] **Step 1: Selftest first.** Add, after `ipv6Scenario`:

```swift
    /// M9b (spec M9 §1): SRV1 serves srv1.lab (AAAA and A) and the sink; R1 advertises it with RDNSS; PC1 learns it, pings the
    /// name over IPv6 and sends TCP and UDP to it; then a rule on R1 denying 2001:db8:1::/64 stops the IPv6 ping, not the IPv4 one.
    private static func ipv6ServicesScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.router, at: Pos(x: 560, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 400, y: 380))
        await editor.addDevice(.server, at: Pos(x: 720, y: 380))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("R1"), id("PC1")) // R1 Gi0/0
        await editor.connect(id("R1"), id("SRV1")) // R1 Gi0/1
        for (name, iface, v4, v6) in [("R1", "Gi0/0", "10.0.1.1/24", "2001:db8:1::1/64"), ("R1", "Gi0/1", "10.0.2.1/24", "2001:db8:2::1/64"),
                                      ("SRV1", "eth0", "10.0.2.53/24", "2001:db8:2::53/64")] {
            await editor.edit(.setIp(node: id(name), iface: iface, cidr: v4))
            await editor.edit(.setIpv6(node: id(name), iface: iface, config: Ipv6Config(address: v6)))
        }
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.1.10/24"))
        await editor.edit(.addRoute(node: id("PC1"), cidr: "0.0.0.0/0", nextHop: "10.0.1.1"))
        await editor.edit(.addRoute(node: id("SRV1"), cidr: "0.0.0.0/0", nextHop: "10.0.2.1"))
        await editor.edit(.setIpv6(node: id("PC1"), iface: "eth0", config: Ipv6Config(autoconfig: true)))
        await editor.edit(.setIpv6Routing(node: id("R1"), on: true))
        await editor.edit(.setRdnss(node: id("R1"), server: "2001:db8:2::53"))
        await editor.enableDns(id("SRV1"), true)
        await editor.addDnsRecord(id("SRV1"), name: "srv1.lab", ip: "2001:db8:2::53", ttl: "")
        await editor.addDnsRecord(id("SRV1"), name: "srv1.lab", ip: "10.0.2.53", ttl: "")
        await editor.edit(.setSink(node: id("SRV1"), on: true))
        for _ in 0..<30 { await editor.tick(wallMs: 100) }
        let pc1 = { editor.snapshot.nodes.first { $0.name == "PC1" } }
        if pc1()?.learnedNameServer != "2001:db8:2::53" { failures.append("PC1 learned \(String(describing: pc1()?.learnedNameServer))") }
        await editor.run(.ping(node: id("PC1"), target: "srv1.lab"))
        await editor.startTraffic(id("PC1"), target: "srv1.lab", kind: .tcp, amount: "1000000", seconds: "")
        await editor.startTraffic(id("PC1"), target: "srv1.lab", kind: .udp, amount: "1", seconds: "1")
        for _ in 0..<50 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if !(apps.first?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false)
            || apps.first?.lines.first != "PING srv1.lab(2001:db8:2::53) 56 data bytes" { failures.append("ping by name over IPv6 \(apps.first?.lines ?? [])") }
        if apps.count != 3 || apps[1].lines.last != "iperf Done." || apps[2].lines.last != "iperf Done." { failures.append("IPv6 traffic \(apps.map(\.lines))") }
        if !(pc1()?.tcp.contains { $0.remote == "[2001:db8:2::53]:9" } ?? false) { failures.append("PC1 TCP rows \(pc1()?.tcp ?? [])") }
        if let reply = editor.events.first(where: { $0.proto == .dns && $0.info.hasPrefix("DNS Risposta") && $0.info.contains("AAAA") }) {
            await editor.selectEvent(reply.id)
            if editor.pdu?.map(\.title) != ["Ethernet II", "IPv6", "UDP", "DNS"] { failures.append("AAAA PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no AAAA answer in the event list")
        }
        await editor.edit(.setFirewall(node: id("R1"), config: FirewallConfig()))
        await editor.addFirewallRule(id("R1"), FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .any, src: "2001:db8:1::/64", dst: ""), port: "")
        await editor.run(.ping(node: id("PC1"), target: "2001:db8:2::53"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.2.53"))
        for _ in 0..<150 { await editor.tick(wallMs: 100) }
        let pings = editor.snapshot.apps.suffix(2).map(\.lines)
        if pings.count != 2 || !pings[0].contains("4 packets transmitted, 0 received, 100% packet loss")
            || !pings[1].contains("4 packets transmitted, 4 received, 0% packet loss") { failures.append("firewall IPv6 \(pings)") }
        editor.select(.node(id("SRV1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m9b-dns")) { failures.append("could not write the M9b DNS image") }
        editor.select(.node(id("R1")))
        if !render(editor, to: sibling(output, "m9b-firewall")) { failures.append("could not write the M9b firewall image") }
        editor.inspectorTab = .routing
        if !render(editor, to: sibling(output, "m9b-routing")) { failures.append("could not write the M9b routing image") }
        editor.select(.node(id("PC1")))
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m9b-tables")) { failures.append("could not write the M9b tables image") }
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m9b-pc")) { failures.append("could not write the M9b host image") }
        return failures
    }
```

In `scenario`, next to `failures += await ipv6Scenario(output: output)`, add `failures += await ipv6ServicesScenario(output: output)`. Run the selftest: it passes or fails only on the engine; the images show the old UI.

- [ ] **Step 2: Implement.**
- `RoutingTab`, inside the router block, after `ErrorLine(editor: editor, key: key)` of the switch (same `VStack`):
  ```swift
                      if node.ipv6Routing {
                          let dnsKey = "rdnss:\(node.id)"
                          CommitField(label: "Server DNS annunciato (RDNSS)", value: node.rdnss ?? "", placeholder: "2001:db8:2::53",
                                      errorKey: dnsKey, editor: editor) { text in
                              let trimmed = text.trimmingCharacters(in: .whitespaces)
                              await editor.edit(.setRdnss(node: node.id, server: trimmed.isEmpty ? nil : trimmed), key: dnsKey)
                          }
                      }
  ```
- Host "Server DNS" placeholder: `node.learnedNameServer.map { "\($0) (da \($0.contains(":") ? "RA" : "DHCP"))" } ?? "10.0.0.53"`.
- `ServicesTab.dns`: header `Text("RECORD A E AAAA")`; row `Text("\(records[i].name)  \(records[i].ip.contains(":") ? "AAAA" : "A")  \(records[i].ip)  TTL \(records[i].ttl)s")` (same modifiers); the IP field placeholder `"IPv4 o IPv6"`.
- `ServicesTab.firewall`: the allow-policy hint becomes `"Indirizzi: any, un IP o un prefisso, IPv4 o IPv6. Le risposte ai flussi consentiti passano sempre."`; the deny one gains ` NS e NA IPv6 passano sempre.`.

- [ ] **Step 3: Verify.** `SELFTEST OK`; read `build/selftest-m9b-dns.png`, `-m9b-firewall.png`, `-m9b-routing.png`, `-m9b-tables.png`, `-m9b-pc.png`: no wrapped or truncated record, rule, field, table row or event description; fix by the established patterns (one-line `minimumScaleFactor`, two values per cell with a `\n` head) and record each fix as a ruling. `scripts/test.sh` count unchanged.
- [ ] **Step 4: Commit** `feat(ui): RDNSS in the Routing tab, AAAA records, IPv6 firewall copy, M9b selftest images`.

---

### Task 9: Docs — M9b manual checklist

**Files:**
- Create: `docs/manual-checks/m9b.md`

- [ ] **Step 1: Write the checklist** in Italian in the style of `docs/manual-checks/m9a.md`: the spec's M9b success lab built by hand (R1, PC1 on SLAAC, SRV1 with AAAA, sink, RDNSS), what to see in Interfacce (server "(da RA)"), Servizi (records A/AAAA, firewall), Routing (RDNSS field, static-route hint), Tabelle (Connessioni TCP `[…]:9`, cache DNS with both records), the event list (DNS Query AAAA, TCP over IPv6, RA with option 25 in the inspector), nslookup output, the firewall rule stopping only the IPv6 ping, a deny-all policy with NS/NA passing, saving and reopening, an M9a file opening without RDNSS.
- [ ] **Step 2: Verify.** `scripts/test.sh` (399), `scripts/selftest.sh` (`SELFTEST OK`), `scripts/bundle.sh` (`build/PacTrack.app`).
- [ ] **Step 3: Commit** `docs: M9b manual checklist`.
