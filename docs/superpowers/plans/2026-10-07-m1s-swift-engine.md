# M1s — Swift port of the engine (PacEngine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the M1 TypeScript engine to a Swift package target `PacEngine` with the same behaviour, the same 69 tests (ported to Swift Testing) and the same exact numbers, then delete the TypeScript engine.

**Architecture:** One Swift Package at the repo root. `PacEngine` is a pure Swift library (Foundation only): a `Sim` owns a min-heap `Scheduler` (integer nanoseconds), a seeded `Rng` and a ring-buffer `EventLog`; `Node`/`Interface`/`Link` model the physical layer; `IpNode` adds ARP, routing, ICMP and UDP; `Ping` and `Traceroute` are app objects. Value types for PDUs, classes for stateful devices. Types stay `internal` — tests use `@testable import`; M2a will mark what the app needs `public`.

**Tech Stack:** Swift 6.3 (language mode 6), Swift Package Manager, Swift Testing — Command Line Tools only, no Xcode.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (revision 2: §4, §5, §10, §11 — milestone M1s). Executable reference: `src/engine/**` (TypeScript, M1) until Task 11 removes it.

## Global Constraints

- **Run every `swift` command outside the sandbox** (`dangerouslyDisableSandbox: true`): inside it SwiftPM cannot write its caches and fails with "Invalid manifest" / "SDK is not supported by the compiler".
- **Run tests with `scripts/test.sh`, never bare `swift test`**: with Command Line Tools only, bare `swift test` builds but silently runs zero tests. The script adds the CLT `Testing` framework paths (verified: passing and failing tests are reported, exit code 1 on failure).
- `PacEngine` imports only Foundation. No SwiftUI/AppKit.
- Behaviour parity with M1: same defaults (MAC aging 300 s, ARP cache 300 s, 3 ARP tries 1 s apart, 3 queued packets, host TTL 64, router TTL 255, MTU 1500, link 1 Gb/s / 500 ns / loss 0 / queue 1000, log 100 000), same error messages, same Linux-style output lines, same exact numbers (98 B echo, 0xB861, RTT 4 329 600 / 2 195 200 ns).
- Time is `Int` nanoseconds; constants `MS`, `S`. IPv4 addresses are `UInt32`; MACs are `String` (`"02:00:00:00:00:0b"`).
- All randomness through `sim.rng` (mulberry32, bit-identical to the TS version — pinned by a parity test).
- Ownership: nodes hold `unowned let sim`; interfaces hold `unowned let node`; an interface owns its `Link` strongly, the link holds its interfaces `unowned`. Callers (tests, later the app) keep the `Sim` and the nodes alive.
- Code, comments, test names and commits in English. Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FbFogmKCbqCctTUt5TujDV
  ```

## Review Focus

1. **Swift `Dictionary` iteration order is randomized per process** → any iteration over a dictionary on the simulation path would break determinism. Pinned: listeners are an ordered array (Task 8) and the determinism test (Task 10) compares two runs.
2. **Retain cycles between nodes, links and closures** → leaked simulations when the app reloads a network (every undo in M2a). Pinned by the ownership rules above; reviewers check every stored reference and every escaping closure.
3. **Integer width traps** (`UInt8`/`UInt16` conversions) on user-sized values (ping size/TTL/count, traceroute ports) → must be rejected by validation, never crash. Pinned in Task 9 and Task 10 option tests.
4. **Malformed user input** (bad IP/CIDR, network/broadcast host address, overlapping subnets, unreachable next hop) → `EngineError` with the M1 message, state unchanged. Pinned in Tasks 3, 7, 8.
5. **Layer-2 loop** → `sim.run` returns, log capped. Pinned in Task 6.

## File Structure

```
Package.swift
scripts/test.sh                         swift test with CLT Testing paths
Sources/PacEngine/
  EngineError.swift   Time.swift   Rng.swift   Scheduler.swift   Address.swift   PDU.swift
  Events.swift        Sim.swift    Node.swift  Link.swift
  Devices/Hub.swift   Devices/Switch.swift   Devices/Host.swift   Devices/Router.swift
  L3/RoutingTable.swift   L3/Arp.swift   L3/IpNode.swift
  Apps/Ping.swift     Apps/Traceroute.swift
Tests/PacEngineTests/
  TestUtils.swift  RngTests.swift  SchedulerTests.swift  AddressTests.swift  PduTests.swift
  LinkTests.swift  L2Tests.swift   RoutingTests.swift    IpTests.swift      PingTests.swift
  TracerouteTests.swift
```

---

### Task 1: Package scaffold, test script, errors, time and RNG

**Files:**
- Create: `Package.swift`, `scripts/test.sh`, `Sources/PacEngine/EngineError.swift`, `Sources/PacEngine/Time.swift`, `Sources/PacEngine/Rng.swift`, `Tests/PacEngineTests/TestUtils.swift`, `Tests/PacEngineTests/RngTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `struct EngineError: Error, CustomStringConvertible { let message: String; init(_:) }`; `let MS: Int`, `let S: Int`; `final class Rng { init(seed: UInt32); func next() -> Double; func int(_ maxExclusive: Int) -> Int }`; test helper `expectError(_ fragment: String, _ body: () throws -> Void)`

- [ ] **Step 1: Scaffold the package and the test script**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PacTrack",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PacEngine"),
        .testTarget(name: "PacEngineTests", dependencies: ["PacEngine"]),
    ]
)
```

`scripts/test.sh`:

```sh
#!/bin/sh
# Runs Swift Testing with Command Line Tools only (no Xcode).
# Without these paths `swift test` builds but runs zero tests.
set -e
if [ -d /Applications/Xcode.app ]; then exec swift test "$@"; fi
DEV=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  "$@"
```

Run: `chmod +x scripts/test.sh`

Append to `.gitignore`:

```
# SwiftPM
.build/
.swiftpm/
```

- [ ] **Step 2: Write the failing test**

`Tests/PacEngineTests/TestUtils.swift`:

```swift
import Testing
@testable import PacEngine

/// Expects `body` to throw an error whose description contains `fragment`.
func expectError(_ fragment: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected an error containing \"\(fragment)\"", sourceLocation: sourceLocation)
    } catch {
        #expect("\(error)".contains(fragment), "got: \(error)", sourceLocation: sourceLocation)
    }
}
```

`Tests/PacEngineTests/RngTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct RngTests {
    @Test func isDeterministicForAGivenSeed() {
        let a = Rng(seed: 42)
        let b = Rng(seed: 42)
        #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
    }

    @Test func matchesTheTypeScriptReferenceBitForBit() {
        let r = Rng(seed: 42)
        #expect([r.next(), r.next(), r.next()] == [0.6011037519201636, 0.44829055899754167, 0.8524657934904099])
        let q = Rng(seed: 1)
        #expect((0..<5).map { _ in q.int(65536) } == [41095, 179, 34566, 64294, 63463])
    }

    @Test func differsAcrossSeedsAndStaysInUnitRange() {
        #expect(Rng(seed: 1).next() != Rng(seed: 2).next())
        let r = Rng(seed: 7)
        for _ in 0..<1000 {
            let v = r.next()
            #expect(v >= 0 && v < 1)
        }
    }

    @Test func intStaysBelowTheBound() {
        let r = Rng(seed: 3)
        for _ in 0..<1000 {
            #expect((0..<10).contains(r.int(10)))
        }
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run (outside the sandbox): `scripts/test.sh`
Expected: build FAIL — `cannot find 'Rng' in scope` (and the target has no sources yet).

- [ ] **Step 4: Implement**

`Sources/PacEngine/EngineError.swift`:

```swift
/// A user-facing validation error. `message` matches the M1 engine's texts.
struct EngineError: Error, CustomStringConvertible, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
```

`Sources/PacEngine/Time.swift`:

```swift
/// Simulated time unit is the nanosecond.
let MS = 1_000_000
let S = 1_000_000_000
```

`Sources/PacEngine/Rng.swift`:

```swift
/// Seeded PRNG (mulberry32), bit-identical to the TypeScript engine. All simulation randomness comes from here.
final class Rng {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    func next() -> Double {
        state &+= 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    func int(_ maxExclusive: Int) -> Int {
        Int(next() * Double(maxExclusive))
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: `Test run with 4 tests … passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift scripts/test.sh .gitignore Sources Tests
git commit -m "chore(swift): scaffold PacEngine package with seeded RNG"
```

---

### Task 2: Scheduler

**Files:**
- Create: `Sources/PacEngine/Scheduler.swift`
- Test: `Tests/PacEngineTests/SchedulerTests.swift`

**Interfaces:**
- Produces: `final class SimTimer { func cancel() }`; `final class Scheduler { private(set) var now: Int; @discardableResult func at(_ time: Int, _ fn: @escaping () -> Void) -> SimTimer; @discardableResult func after(_ delay: Int, _ fn:) -> SimTimer; @discardableResult func step() -> Bool; func runUntil(_ time: Int) }` — scheduling in the past is a programming error (`precondition`).

- [ ] **Step 1: Write the failing test**

`Tests/PacEngineTests/SchedulerTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct SchedulerTests {
    @Test func runsEventsInTimeOrderAndAdvancesNow() {
        let s = Scheduler()
        var seen: [String] = []
        s.at(30) { seen.append("c@\(s.now)") }
        s.at(10) { seen.append("a@\(s.now)") }
        s.at(20) { seen.append("b@\(s.now)") }
        s.runUntil(100)
        #expect(seen == ["a@10", "b@20", "c@30"])
        #expect(s.now == 100)
    }

    @Test func keepsFifoOrderForEventsAtTheSameTime() {
        let s = Scheduler()
        var seen: [Int] = []
        for i in 0..<5 { s.at(10) { seen.append(i) } }
        s.runUntil(10)
        #expect(seen == [0, 1, 2, 3, 4])
    }

    @Test func runsEventsScheduledDuringExecutionInTheSameWindow() {
        let s = Scheduler()
        var seen: [Int] = []
        s.at(5) { s.after(0) { seen.append(s.now) } }
        s.runUntil(5)
        #expect(seen == [5])
    }

    @Test func doesNotRunEventsBeyondTheTarget() {
        let s = Scheduler()
        var ran = false
        s.at(11) { ran = true }
        s.runUntil(10)
        #expect(!ran)
        #expect(s.now == 10)
    }

    @Test func cancelledTimersNeverFireAndDoNotBlockLaterEvents() {
        let s = Scheduler()
        var seen: [String] = []
        let t = s.at(5) { seen.append("cancelled") }
        s.at(20) { seen.append("late") }
        t.cancel()
        s.runUntil(10)
        #expect(seen.isEmpty)
        #expect(s.now == 10)
        s.runUntil(20)
        #expect(seen == ["late"])
    }

    @Test func schedulingInThePastIsAProgrammingError() async {
        await #expect(processExitsWith: .failure) {
            let s = Scheduler()
            s.runUntil(50)
            s.at(10) {}
        }
    }

    @Test func stepReturnsFalseWhenIdle() {
        #expect(!Scheduler().step())
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter SchedulerTests`
Expected: build FAIL — `cannot find 'Scheduler' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Scheduler.swift`:

```swift
/// Handle for a scheduled event.
final class SimTimer {
    fileprivate let time: Int
    fileprivate let seq: Int
    fileprivate let fn: () -> Void
    fileprivate var cancelled = false

    fileprivate init(time: Int, seq: Int, fn: @escaping () -> Void) {
        self.time = time
        self.seq = seq
        self.fn = fn
    }

    func cancel() {
        cancelled = true
    }
}

/// Min-heap of events ordered by (time, insertion seq) for deterministic ties.
final class Scheduler {
    private(set) var now = 0
    private var heap: [SimTimer] = []
    private var seq = 0

    @discardableResult
    func at(_ time: Int, _ fn: @escaping () -> Void) -> SimTimer {
        precondition(time >= now, "Cannot schedule in the past (\(time) < \(now))")
        let timer = SimTimer(time: time, seq: seq, fn: fn)
        seq += 1
        push(timer)
        return timer
    }

    @discardableResult
    func after(_ delay: Int, _ fn: @escaping () -> Void) -> SimTimer {
        at(now + delay, fn)
    }

    /// Runs the next live event. Returns false when nothing is pending.
    @discardableResult
    func step() -> Bool {
        guard let timer = peek() else { return false }
        pop()
        now = timer.time
        timer.fn()
        return true
    }

    func runUntil(_ time: Int) {
        while let timer = peek(), timer.time <= time { step() }
        if time > now { now = time }
    }

    private func peek() -> SimTimer? {
        while let first = heap.first, first.cancelled { pop() }
        return heap.first
    }

    private func less(_ a: SimTimer, _ b: SimTimer) -> Bool {
        a.time < b.time || (a.time == b.time && a.seq < b.seq)
    }

    private func push(_ timer: SimTimer) {
        heap.append(timer)
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(heap[i], heap[parent]) else { break }
            heap.swapAt(i, parent)
            i = parent
        }
    }

    @discardableResult
    private func pop() -> SimTimer? {
        guard !heap.isEmpty else { return nil }
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1
                let r = l + 1
                var m = i
                if l < heap.count && less(heap[l], heap[m]) { m = l }
                if r < heap.count && less(heap[r], heap[m]) { m = r }
                if m == i { break }
                heap.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 11 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Scheduler.swift Tests/PacEngineTests/SchedulerTests.swift
git commit -m "feat(swift): add deterministic discrete-event scheduler"
```

---

### Task 3: Addresses

**Files:**
- Create: `Sources/PacEngine/Address.swift`
- Test: `Tests/PacEngineTests/AddressTests.swift`

**Interfaces:**
- Produces: `typealias Mac = String`; `BROADCAST_MAC`; `BROADCAST_IP: UInt32`; `struct Cidr: Equatable { var addr: UInt32; var prefix: Int }`; `parseIp(_:) throws -> UInt32`; `formatIp(_:) -> String`; `parseCidr(_:) throws -> Cidr`; `prefixMask(_:) -> UInt32`; `networkOf(_:_:)`, `broadcastOf(_:_:)`, `inSubnet(_:_:_:)`; `macFromIndex(_:) -> Mac`; `isGroupMac(_:) -> Bool`

- [ ] **Step 1: Write the failing test**

`Tests/PacEngineTests/AddressTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct AddressTests {
    @Test func roundTripsDottedQuads() throws {
        for ip in ["0.0.0.0", "10.0.0.1", "192.168.1.254", "255.255.255.255"] {
            #expect(formatIp(try parseIp(ip)) == ip)
        }
        #expect(try parseIp("192.168.0.1") == 0xC0A8_0001)
    }

    @Test func rejectsMalformedAddresses() {
        for bad in ["10.0.0.256", "10.0.0", "10.0.0.1.2", "a.b.c.d", "01.2.3.4", " 10.0.0.1", "", "-1.0.0.0"] {
            expectError("Invalid IPv4 address: \"\(bad)\"") { _ = try parseIp(bad) }
        }
    }

    @Test func parsesCidrAndRejectsBadPrefixes() throws {
        #expect(try parseCidr("10.0.0.5/24") == Cidr(addr: try parseIp("10.0.0.5"), prefix: 24))
        #expect(try parseCidr("0.0.0.0/0") == Cidr(addr: 0, prefix: 0))
        for bad in ["10.0.0.1/33", "10.0.0.1", "10.0.0.1/", "10.0.0.1/ 24", "10.0.0.1/24/1", "10.0.0.1/024"] {
            expectError("Invalid") { _ = try parseCidr(bad) }
        }
    }

    @Test func computesMasksNetworksAndBroadcasts() throws {
        #expect(prefixMask(0) == 0)
        #expect(prefixMask(24) == 0xFFFF_FF00)
        #expect(prefixMask(32) == 0xFFFF_FFFF)
        #expect(formatIp(networkOf(try parseIp("10.0.0.5"), 30)) == "10.0.0.4")
        #expect(formatIp(broadcastOf(try parseIp("10.0.0.5"), 30)) == "10.0.0.7")
        #expect(inSubnet(try parseIp("192.168.1.77"), try parseIp("192.168.1.0"), 24))
        #expect(!inSubnet(try parseIp("192.168.2.1"), try parseIp("192.168.1.0"), 24))
        #expect(inSubnet(try parseIp("8.8.8.8"), 0, 0))
    }

    @Test func generatesLocallyAdministeredUnicastMacs() {
        #expect(macFromIndex(11) == "02:00:00:00:00:0b")
        #expect(macFromIndex(0x0102_0304) == "02:00:01:02:03:04")
        #expect(!isGroupMac(macFromIndex(1)))
    }

    @Test func detectsBroadcastAndMulticast() {
        #expect(isGroupMac("ff:ff:ff:ff:ff:ff"))
        #expect(isGroupMac("01:00:5e:00:00:01"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter AddressTests`
Expected: build FAIL — `cannot find 'parseIp' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Address.swift`:

```swift
/// MAC address, lowercase colon-separated: "02:00:00:00:00:0b".
typealias Mac = String

let BROADCAST_MAC: Mac = "ff:ff:ff:ff:ff:ff"
let BROADCAST_IP: UInt32 = 0xFFFF_FFFF

struct Cidr: Equatable, Sendable {
    var addr: UInt32
    var prefix: Int
}

/// Plain decimal without sign, spaces or leading zeros, at most `max`.
private func decimal(_ s: Substring, max: Int) -> Int? {
    guard !s.isEmpty, s.count <= 3, s.allSatisfy({ $0.isASCII && $0.isNumber }), s == "0" || s.first != "0",
          let value = Int(s), value <= max else { return nil }
    return value
}

func parseIp(_ s: String) throws -> UInt32 {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { throw EngineError("Invalid IPv4 address: \"\(s)\"") }
    var n: UInt32 = 0
    for part in parts {
        guard let octet = decimal(part, max: 255) else { throw EngineError("Invalid IPv4 address: \"\(s)\"") }
        n = n << 8 | UInt32(octet)
    }
    return n
}

func formatIp(_ n: UInt32) -> String {
    "\(n >> 24).\((n >> 16) & 255).\((n >> 8) & 255).\(n & 255)"
}

func parseCidr(_ s: String) throws -> Cidr {
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = decimal(parts[1], max: 32) else { throw EngineError("Invalid CIDR: \"\(s)\"") }
    return Cidr(addr: try parseIp(String(parts[0])), prefix: prefix)
}

func prefixMask(_ prefix: Int) -> UInt32 {
    prefix == 0 ? 0 : UInt32.max << (32 - prefix)
}

func networkOf(_ addr: UInt32, _ prefix: Int) -> UInt32 {
    addr & prefixMask(prefix)
}

func broadcastOf(_ addr: UInt32, _ prefix: Int) -> UInt32 {
    networkOf(addr, prefix) | ~prefixMask(prefix)
}

func inSubnet(_ addr: UInt32, _ network: UInt32, _ prefix: Int) -> Bool {
    networkOf(addr, prefix) == networkOf(network, prefix)
}

private func hex2(_ b: Int) -> String {
    let h = String(b, radix: 16)
    return h.count == 1 ? "0" + h : h
}

func macFromIndex(_ i: Int) -> Mac {
    [0x02, 0x00, (i >> 24) & 255, (i >> 16) & 255, (i >> 8) & 255, i & 255].map(hex2).joined(separator: ":")
}

/// True for broadcast and multicast MACs (I/G bit set).
func isGroupMac(_ mac: Mac) -> Bool {
    (Int(mac.prefix(2), radix: 16) ?? 0) & 1 == 1
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 17 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Address.swift Tests/PacEngineTests/AddressTests.swift
git commit -m "feat(swift): add IPv4/CIDR/MAC address helpers"
```

---

### Task 4: PDUs, sizes and checksums

**Files:**
- Create: `Sources/PacEngine/PDU.swift`
- Test: `Tests/PacEngineTests/PduTests.swift`

**Interfaces:**
- Consumes: `Mac` (Task 3)
- Produces: constants `ETHERTYPE_IPV4/ARP: UInt16`, `IPPROTO_ICMP/UDP: UInt8`, `ICMP_ECHO_REPLY/DEST_UNREACH/ECHO_REQUEST/TIME_EXCEEDED: UInt8`, `UNREACH_NET/HOST/PORT/FRAG_NEEDED: UInt8`; `struct ArpPacket { op: UInt16; senderMac; senderIp: UInt32; targetMac; targetIp: UInt32 }`; `struct IcmpMessage { type, code: UInt8; checksum, id, seq: UInt16; data: [UInt8] }`; `struct UdpDatagram { srcPort, dstPort, checksum: UInt16; data: [UInt8] }`; `enum L4 { icmp, udp }`; `struct Ipv4Packet { tos: UInt8; id: UInt16; dontFragment: Bool; ttl: UInt8; proto: UInt8; checksum: UInt16; src, dst: UInt32; payload: L4 }`; `enum L3 { arp, ipv4 }`; `struct EthernetFrame { id: Int; src, dst: Mac; etherType: UInt16; payload: L3 }`; `.size` on all, `EthernetFrame.wireBytes`; `internetChecksum`, `serialize(_ IcmpMessage)`, `serialize(_ UdpDatagram)`, `serializeHeader`, `serializeL4`, `makeIcmp(type:code:id:seq:data:)`, `makeUdp(srcPort:dstPort:data:)`, `makeIpv4(src:dst:ttl:id:payload:tos:dontFragment:)`, `withTtl(_:_:)`

- [ ] **Step 1: Write the failing test**

`Tests/PacEngineTests/PduTests.swift`:

```swift
import Testing
@testable import PacEngine

private func echo(_ length: Int = 56) -> IcmpMessage {
    makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: 1, seq: 1, data: [UInt8](repeating: 0, count: length))
}

@Suite struct PduTests {
    @Test func matchesTheClassicIpv4HeaderExample() throws {
        // 4500 0073 0000 4000 4011 xxxx c0a8 0001 c0a8 00c7
        let p = makeIpv4(src: try parseIp("192.168.0.1"), dst: try parseIp("192.168.0.199"), ttl: 64, id: 0,
                         payload: .udp(makeUdp(srcPort: 1, dstPort: 2, data: [UInt8](repeating: 0, count: 87))))
        #expect(p.size == 0x73)
        #expect(p.checksum == 0xB861)
    }

    @Test func producesHeadersThatVerifyToZero() throws {
        let m = echo()
        let p = makeIpv4(src: try parseIp("10.0.0.1"), dst: try parseIp("10.0.0.2"), ttl: 64, id: 7, payload: .icmp(m))
        #expect(internetChecksum(serializeHeader(p)) == 0)
        #expect(internetChecksum(serialize(m)) == 0)
    }

    @Test func withTtlReturnsANewPacketWithAValidChecksum() throws {
        let p = makeIpv4(src: try parseIp("10.0.0.1"), dst: try parseIp("10.0.0.2"), ttl: 64, id: 7, payload: .icmp(echo()))
        let q = withTtl(p, 63)
        #expect(p.ttl == 64)
        #expect(q.ttl == 63)
        #expect(q.checksum != p.checksum)
        #expect(internetChecksum(serializeHeader(q)) == 0)
    }

    @Test func handlesOddLengthInput() {
        #expect(internetChecksum([0x01]) == 0xFEFF)
    }

    @Test func icmpEchoWith56BytesIs98BytesOnEthernetAnd122OnTheWire() {
        let p = makeIpv4(src: 1, dst: 2, ttl: 64, id: 1, payload: .icmp(echo()))
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV4, payload: .ipv4(p))
        #expect(p.size == 84)
        #expect(f.size == 98)
        #expect(f.wireBytes == 122)
    }

    @Test func arpFrameIs42BytesPaddedTo64PlusOverhead() {
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: BROADCAST_MAC, etherType: ETHERTYPE_ARP,
                              payload: .arp(ArpPacket(op: 1, senderMac: "02:00:00:00:00:01", senderIp: 1, targetMac: "00:00:00:00:00:00", targetIp: 2)))
        #expect(f.size == 42)
        #expect(f.wireBytes == 84)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter PduTests`
Expected: build FAIL — `cannot find 'makeIcmp' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/PDU.swift`:

```swift
let ETHERTYPE_IPV4: UInt16 = 0x0800
let ETHERTYPE_ARP: UInt16 = 0x0806
let IPPROTO_ICMP: UInt8 = 1
let IPPROTO_UDP: UInt8 = 17

let ICMP_ECHO_REPLY: UInt8 = 0
let ICMP_DEST_UNREACH: UInt8 = 3
let ICMP_ECHO_REQUEST: UInt8 = 8
let ICMP_TIME_EXCEEDED: UInt8 = 11
let UNREACH_NET: UInt8 = 0
let UNREACH_HOST: UInt8 = 1
let UNREACH_PORT: UInt8 = 3
let UNREACH_FRAG_NEEDED: UInt8 = 4

struct ArpPacket: Equatable, Sendable {
    var op: UInt16
    var senderMac: Mac
    var senderIp: UInt32
    var targetMac: Mac
    var targetIp: UInt32
}

/// Echo uses id/seq; error messages leave them 0 and carry the quoted datagram in `data`.
struct IcmpMessage: Equatable, Sendable {
    var type: UInt8
    var code: UInt8
    var checksum: UInt16
    var id: UInt16
    var seq: UInt16
    var data: [UInt8]

    var size: Int { 8 + data.count }
}

struct UdpDatagram: Equatable, Sendable {
    var srcPort: UInt16
    var dstPort: UInt16
    var checksum: UInt16
    var data: [UInt8]

    var size: Int { 8 + data.count }
}

enum L4: Equatable, Sendable {
    case icmp(IcmpMessage)
    case udp(UdpDatagram)

    var size: Int {
        switch self {
        case .icmp(let m): m.size
        case .udp(let u): u.size
        }
    }
}

struct Ipv4Packet: Equatable, Sendable {
    var tos: UInt8
    var id: UInt16
    var dontFragment: Bool
    var ttl: UInt8
    var proto: UInt8
    var checksum: UInt16
    var src: UInt32
    var dst: UInt32
    var payload: L4

    var size: Int { 20 + payload.size }
}

enum L3: Equatable, Sendable {
    case arp(ArpPacket)
    case ipv4(Ipv4Packet)
}

struct EthernetFrame: Equatable, Sendable {
    var id: Int
    var src: Mac
    var dst: Mac
    var etherType: UInt16
    var payload: L3

    /// Size as shown by Wireshark: Ethernet header + payload, no FCS.
    var size: Int {
        switch payload {
        case .arp: 14 + 28
        case .ipv4(let p): 14 + p.size
        }
    }

    /// Bytes occupying the wire: frame + FCS padded to 64, plus preamble/SFD (8) and inter-frame gap (12).
    var wireBytes: Int { max(size + 4, 64) + 20 }
}

func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i < bytes.count {
        sum += UInt32(bytes[i]) << 8 + (i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0)
        i += 2
    }
    while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum)
}

private func u16(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 0xFF)] }
private func u32(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }

func serialize(_ m: IcmpMessage) -> [UInt8] {
    var b: [UInt8] = [m.type, m.code]
    b += u16(m.checksum)
    b += u16(m.id)
    b += u16(m.seq)
    return b + m.data
}

func serialize(_ u: UdpDatagram) -> [UInt8] {
    var b = u16(u.srcPort)
    b += u16(u.dstPort)
    b += u16(UInt16(u.size))
    b += u16(u.checksum)
    return b + u.data
}

func serializeHeader(_ p: Ipv4Packet) -> [UInt8] {
    var b: [UInt8] = [0x45, p.tos]
    b += u16(UInt16(p.size))
    b += u16(p.id)
    b += [p.dontFragment ? 0x40 : 0, 0, p.ttl, p.proto]
    b += u16(p.checksum)
    b += u32(p.src)
    b += u32(p.dst)
    return b
}

func serializeL4(_ p: Ipv4Packet) -> [UInt8] {
    switch p.payload {
    case .icmp(let m): serialize(m)
    case .udp(let u): serialize(u)
    }
}

func makeIcmp(type: UInt8, code: UInt8, id: UInt16, seq: UInt16, data: [UInt8]) -> IcmpMessage {
    var m = IcmpMessage(type: type, code: code, checksum: 0, id: id, seq: seq, data: data)
    m.checksum = internetChecksum(serialize(m))
    return m
}

func makeUdp(srcPort: UInt16, dstPort: UInt16, data: [UInt8]) -> UdpDatagram {
    // ponytail: UDP checksum left 0 (optional over IPv4, RFC 768); add pseudo-header checksum if a lab needs it
    UdpDatagram(srcPort: srcPort, dstPort: dstPort, checksum: 0, data: data)
}

private func withChecksum(_ p: Ipv4Packet) -> Ipv4Packet {
    var q = p
    q.checksum = 0
    q.checksum = internetChecksum(serializeHeader(q))
    return q
}

func makeIpv4(src: UInt32, dst: UInt32, ttl: UInt8, id: UInt16, payload: L4, tos: UInt8 = 0, dontFragment: Bool = true) -> Ipv4Packet {
    let proto: UInt8 = switch payload {
    case .icmp: IPPROTO_ICMP
    case .udp: IPPROTO_UDP
    }
    return withChecksum(Ipv4Packet(tos: tos, id: id, dontFragment: dontFragment, ttl: ttl, proto: proto,
                                   checksum: 0, src: src, dst: dst, payload: payload))
}

func withTtl(_ p: Ipv4Packet, _ ttl: UInt8) -> Ipv4Packet {
    var q = p
    q.ttl = ttl
    return withChecksum(q)
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 23 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/PDU.swift Tests/PacEngineTests/PduTests.swift
git commit -m "feat(swift): add PDU types, sizes and internet checksum"
```

---

### Task 5: Physical layer — EventLog, Sim, Node/Interface, Link

**Files:**
- Create: `Sources/PacEngine/Events.swift`, `Sources/PacEngine/Sim.swift`, `Sources/PacEngine/Node.swift`, `Sources/PacEngine/Link.swift`
- Modify: `Tests/PacEngineTests/TestUtils.swift` (append `Probe`, `drops`)
- Test: `Tests/PacEngineTests/LinkTests.swift`

**Interfaces:**
- Consumes: `Scheduler`, `SimTimer` (Task 2), `Rng` (Task 1), `Mac`, `macFromIndex`, `BROADCAST_MAC`, `Cidr` (Task 3), PDUs (Task 4)
- Produces:
  - `enum EventKind { tx, rx, drop }`; `enum DropReason: String { queueFull = "queue-full", loss, linkDown = "link-down", ifaceDown = "iface-down", noLink = "no-link", arpTimeout = "arp-timeout", arpPendingFull = "arp-pending-full", noRoute = "no-route", ttlExpired = "ttl-expired", mtuExceeded = "mtu-exceeded" }`
  - `struct SimEvent { seq; time; kind; node: String; iface: String?; frame: EthernetFrame?; packet: Ipv4Packet?; reason: DropReason? }`; `final class EventLog { init(capacity: Int = 100_000); func push(_:); var all: [SimEvent]; var size: Int; private(set) var total: Int }`
  - `final class Sim { init(seed: UInt32 = 1, logCapacity: Int = 100_000); let sched; let rng; let log; var now: Int; func nextId() -> Int; func newMac() -> Mac; func emit(_ kind:, node:, iface:, frame:, packet:, reason:); func run(_ duration: Int) }`
  - `final class Interface { unowned let node: Node; let name; let mac; var link: Link?; var up; var mtu = 1500; var ipv4: Cidr?; var id: String; func send(_:) }`; `class Node { unowned let sim; let id; var name; private(set) var interfaces; var powered; @discardableResult func addInterface(_:) -> Interface; func iface(_:) throws -> Interface; func receive(_ frame:, on iface:) }`
  - `struct LinkOptions { var bandwidthBps: Double = 1e9; var propDelayNs = 500; var lossRate = 0.0; var queueLimit = 1000 }`; `final class Link { init(sim:, _ a:, _ b:, _ opts: LinkOptions = .init()) throws; var up; let opts; unowned let a, b; func peer(_:) -> Interface; func transmit(from:, _ frame:) }`
  - test utils: `final class Probe: Node { var got: [(frame: EthernetFrame, iface: String, time: Int)]; @discardableResult func sendRaw(_ dst: Mac = BROADCAST_MAC) throws -> EthernetFrame }`; `drops(_ sim:, _ reason:) -> Int`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PacEngineTests/TestUtils.swift`:

```swift
/// Minimal node that records every frame it receives and can emit raw frames.
final class Probe: Node {
    var got: [(frame: EthernetFrame, iface: String, time: Int)] = []

    init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("eth0")
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        got.append((frame, iface.name, sim.now))
    }

    @discardableResult
    func sendRaw(_ dst: Mac = BROADCAST_MAC) throws -> EthernetFrame {
        let i = try iface("eth0")
        let frame = EthernetFrame(id: sim.nextId(), src: i.mac, dst: dst, etherType: ETHERTYPE_ARP,
                                  payload: .arp(ArpPacket(op: 1, senderMac: i.mac, senderIp: 0, targetMac: "00:00:00:00:00:00", targetIp: 0)))
        i.send(frame)
        return frame
    }
}

func drops(_ sim: Sim, _ reason: DropReason) -> Int {
    sim.log.all.filter { $0.kind == .drop && $0.reason == reason }.count
}
```

`Tests/PacEngineTests/LinkTests.swift`:

```swift
import Testing
@testable import PacEngine

private func pair(_ opts: LinkOptions = LinkOptions()) throws -> (sim: Sim, a: Probe, b: Probe, link: Link) {
    let sim = Sim()
    let a = Probe(sim: sim, id: "A")
    let b = Probe(sim: sim, id: "B")
    let link = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"), opts)
    return (sim, a, b, link)
}

@Suite struct EventLogTests {
    @Test func keepsTheMostRecentEventsInOrderOnceFull() {
        let log = EventLog(capacity: 3)
        for t in 0..<5 { log.push(SimEvent(time: t, kind: .tx, node: "A")) }
        #expect(log.size == 3)
        #expect(log.total == 5)
        #expect(log.all.map { $0.time } == [2, 3, 4])
        #expect(log.all.map { $0.seq } == [2, 3, 4])
    }
}

@Suite struct LinkTests {
    @Test func firstFrameArrivesAfter672Plus500NsAndTheNextBackToBack() throws {
        let (sim, a, b, _) = try pair()
        try a.sendRaw()
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.map { $0.time } == [1172, 1844])
        let first = try #require(sim.log.all.first)
        #expect(first.kind == .tx && first.node == "A" && first.iface == "eth0" && first.time == 0)
    }

    @Test func tailDropsWhenTheQueueIsFull() throws {
        let (sim, a, b, _) = try pair(LinkOptions(queueLimit: 2))
        for _ in 0..<5 { try a.sendRaw() }
        sim.run(MS)
        #expect(b.got.count == 3)
        #expect(drops(sim, .queueFull) == 2)
    }

    @Test func dropsLostFramesAtTheReceiver() throws {
        let (sim, a, b, _) = try pair(LinkOptions(lossRate: 1))
        try a.sendRaw()
        sim.run(MS)
        #expect(b.got.isEmpty)
        #expect(drops(sim, .loss) == 1)
    }

    @Test func dropsWhenTheLinkInterfaceOrCableIsMissingOrDown() throws {
        let (sim, a, _, link) = try pair()
        link.up = false
        try a.sendRaw()
        try a.iface("eth0").up = false
        try a.sendRaw()
        let lonely = Probe(sim: sim, id: "C")
        try lonely.sendRaw()
        sim.run(MS)
        #expect(drops(sim, .linkDown) == 1)
        #expect(drops(sim, .ifaceDown) == 1)
        #expect(drops(sim, .noLink) == 1)
    }

    @Test func neverTransmitsAFrameInZeroTime() throws {
        let (sim, a, b, _) = try pair(LinkOptions(bandwidthBps: 1e15, propDelayNs: 0))
        try a.sendRaw()
        sim.run(MS)
        #expect(try #require(b.got.first).time > 0)
    }

    @Test func rejectsInvalidLinkOptions() throws {
        let invalid = [LinkOptions(bandwidthBps: 0), LinkOptions(propDelayNs: -5), LinkOptions(lossRate: 1.5),
                       LinkOptions(lossRate: -0.1), LinkOptions(queueLimit: -1), LinkOptions(bandwidthBps: .nan)]
        for opts in invalid {
            let sim = Sim()
            let a = Probe(sim: sim, id: "A")
            let b = Probe(sim: sim, id: "B")
            expectError("Invalid link options") { _ = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"), opts) }
            #expect(try a.iface("eth0").link == nil)
        }
    }

    @Test func refusesSelfLinksAndDoubleConnections() throws {
        let (sim, a, b, _) = try pair()
        let c = Probe(sim: sim, id: "C")
        a.addInterface("eth1")
        expectError("itself") { _ = try Link(sim: sim, try a.iface("eth1"), try a.iface("eth0")) }
        expectError("already connected") { _ = try Link(sim: sim, try c.iface("eth0"), try b.iface("eth0")) }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `scripts/test.sh --filter LinkTests`
Expected: build FAIL — `cannot find type 'Node' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Events.swift`:

```swift
enum EventKind: Sendable {
    case tx, rx, drop
}

enum DropReason: String, Sendable {
    case queueFull = "queue-full"
    case loss
    case linkDown = "link-down"
    case ifaceDown = "iface-down"
    case noLink = "no-link"
    case arpTimeout = "arp-timeout"
    case arpPendingFull = "arp-pending-full"
    case noRoute = "no-route"
    case ttlExpired = "ttl-expired"
    case mtuExceeded = "mtu-exceeded"
}

struct SimEvent: Sendable {
    var seq = 0
    var time: Int
    var kind: EventKind
    var node: String
    var iface: String? = nil
    var frame: EthernetFrame? = nil
    var packet: Ipv4Packet? = nil
    var reason: DropReason? = nil
}

/// Ring buffer: keeps the latest `capacity` events.
final class EventLog {
    let capacity: Int
    private var buffer: [SimEvent] = []
    private var start = 0
    /// Events ever pushed, including those evicted.
    private(set) var total = 0

    init(capacity: Int = 100_000) {
        self.capacity = capacity
    }

    func push(_ event: SimEvent) {
        var e = event
        e.seq = total
        total += 1
        if buffer.count < capacity {
            buffer.append(e)
        } else {
            buffer[start] = e
            start = (start + 1) % capacity
        }
    }

    var all: [SimEvent] { Array(buffer[start...]) + buffer[..<start] }
    var size: Int { buffer.count }
}
```

`Sources/PacEngine/Sim.swift`:

```swift
final class Sim {
    let sched = Scheduler()
    let rng: Rng
    let log: EventLog
    private var ids = 0
    private var macs = 0

    init(seed: UInt32 = 1, logCapacity: Int = 100_000) {
        rng = Rng(seed: seed)
        log = EventLog(capacity: logCapacity)
    }

    var now: Int { sched.now }

    func nextId() -> Int {
        ids += 1
        return ids
    }

    func newMac() -> Mac {
        macs += 1
        return macFromIndex(macs)
    }

    func emit(_ kind: EventKind, node: String, iface: String? = nil, frame: EthernetFrame? = nil,
              packet: Ipv4Packet? = nil, reason: DropReason? = nil) {
        log.push(SimEvent(time: now, kind: kind, node: node, iface: iface, frame: frame, packet: packet, reason: reason))
    }

    func run(_ duration: Int) {
        sched.runUntil(now + duration)
    }
}
```

`Sources/PacEngine/Node.swift`:

```swift
final class Interface {
    unowned let node: Node
    let name: String
    let mac: Mac
    /// The cable plugged in here. The interface owns it; the link refers back `unowned`.
    var link: Link?
    var up = true
    var mtu = 1500
    var ipv4: Cidr?

    init(node: Node, name: String, mac: Mac) {
        self.node = node
        self.name = name
        self.mac = mac
    }

    var id: String { "\(node.id)/\(name)" }

    func send(_ frame: EthernetFrame) {
        let reason: DropReason? = !node.powered || !up ? .ifaceDown : link == nil ? .noLink : nil
        if let reason {
            node.sim.emit(.drop, node: node.id, iface: name, frame: frame, reason: reason)
            return
        }
        link!.transmit(from: self, frame)
    }
}

/// Base class of every device. Subclasses override `receive`.
class Node {
    unowned let sim: Sim
    let id: String
    var name: String
    private(set) var interfaces: [Interface] = []
    var powered = true

    init(sim: Sim, id: String) {
        self.sim = sim
        self.id = id
        name = id
    }

    @discardableResult
    func addInterface(_ name: String) -> Interface {
        let iface = Interface(node: self, name: name, mac: sim.newMac())
        interfaces.append(iface)
        return iface
    }

    func iface(_ name: String) throws -> Interface {
        guard let iface = interfaces.first(where: { $0.name == name }) else { throw EngineError("\(id) has no interface \(name)") }
        return iface
    }

    func receive(_ frame: EthernetFrame, on iface: Interface) {
        fatalError("\(type(of: self)) must override receive(_:on:)")
    }
}
```

`Sources/PacEngine/Link.swift`:

```swift
/// Defaults: 1 Gb/s copper, ~100 m.
struct LinkOptions: Sendable {
    var bandwidthBps: Double = 1e9
    var propDelayNs = 500
    var lossRate = 0.0
    var queueLimit = 1000
}

private final class Direction {
    var queue: [EthernetFrame] = []
    var busy = false
}

/// Full-duplex point-to-point link with a FIFO tail-drop queue per direction.
final class Link {
    var up = true
    let opts: LinkOptions
    unowned let sim: Sim
    unowned let a: Interface
    unowned let b: Interface
    private let dirA = Direction()
    private let dirB = Direction()

    init(sim: Sim, _ a: Interface, _ b: Interface, _ opts: LinkOptions = LinkOptions()) throws {
        guard a.node !== b.node else { throw EngineError("Cannot connect a node to itself") }
        guard a.link == nil, b.link == nil else { throw EngineError("Interface already connected: \(a.link != nil ? a.id : b.id)") }
        guard opts.bandwidthBps > 0, opts.propDelayNs >= 0, (0...1).contains(opts.lossRate), opts.queueLimit >= 0 else {
            throw EngineError("Invalid link options: \(opts)")
        }
        self.sim = sim
        self.a = a
        self.b = b
        self.opts = opts
        a.link = self
        b.link = self
    }

    func peer(_ i: Interface) -> Interface { i === a ? b : a }

    private func direction(_ from: Interface) -> Direction { from === a ? dirA : dirB }

    func transmit(from: Interface, _ frame: EthernetFrame) {
        guard up else { return drop(at: from, frame, .linkDown) }
        let dir = direction(from)
        if !dir.busy { return startTx(from, dir, frame) }
        guard dir.queue.count < opts.queueLimit else { return drop(at: from, frame, .queueFull) }
        dir.queue.append(frame)
    }

    private func startTx(_ from: Interface, _ dir: Direction, _ frame: EthernetFrame) {
        dir.busy = true
        sim.emit(.tx, node: from.node.id, iface: from.name, frame: frame)
        // At least 1 ns, so time always advances (a zero-time loop would never end).
        let txNs = max(1, Int((Double(frame.wireBytes * 8) * Double(S) / opts.bandwidthBps).rounded()))
        sim.sched.after(txNs) { [self] in
            let to = peer(from)
            let lost = opts.lossRate > 0 && sim.rng.next() < opts.lossRate
            sim.sched.after(opts.propDelayNs) { [self] in arrive(to, frame, lost) }
            if dir.queue.isEmpty {
                dir.busy = false
            } else {
                startTx(from, dir, dir.queue.removeFirst())
            }
        }
    }

    private func arrive(_ to: Interface, _ frame: EthernetFrame, _ lost: Bool) {
        if lost { return drop(at: to, frame, .loss) }
        guard up, to.up, to.node.powered else { return drop(at: to, frame, .linkDown) }
        sim.emit(.rx, node: to.node.id, iface: to.name, frame: frame)
        to.node.receive(frame, on: to)
    }

    private func drop(at iface: Interface, _ frame: EthernetFrame, _ reason: DropReason) {
        sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: frame, reason: reason)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 31 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine Tests/PacEngineTests
git commit -m "feat(swift): add sim context, interfaces and queued links"
```

---

### Task 6: Hub and learning Switch

**Files:**
- Create: `Sources/PacEngine/Devices/Hub.swift`, `Sources/PacEngine/Devices/Switch.swift`
- Test: `Tests/PacEngineTests/L2Tests.swift`

**Interfaces:**
- Produces: `final class Hub: Node { init(sim:id:ports: Int = 8) }` — ports `p1…pN`; `let MAC_AGING_NS`; `final class Switch: Node { init(sim:id:ports: Int = 8); func lookup(_ mac: Mac) -> Interface? }` — ports `Gi0/1…Gi0/N`

- [ ] **Step 1: Write the failing test**

`Tests/PacEngineTests/L2Tests.swift`:

```swift
import Testing
@testable import PacEngine

private func star(_ sim: Sim, _ device: Node, _ names: [String]) throws -> [Probe] {
    try names.enumerated().map { i, name in
        let p = Probe(sim: sim, id: name)
        _ = try Link(sim: sim, try p.iface("eth0"), device.interfaces[i])
        return p
    }
}

@Suite struct L2Tests {
    @Test func hubRepeatsEveryFrameToAllOtherConnectedPorts() throws {
        let sim = Sim()
        let probes = try star(sim, Hub(sim: sim, id: "HUB"), ["A", "B", "C"])
        try probes[0].sendRaw(try probes[1].iface("eth0").mac)
        sim.run(MS)
        #expect(probes.map { $0.got.count } == [0, 1, 1])
    }

    @Test func switchFloodsUnknownDestinationsThenForwardsLearnedOnes() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B", "C"])
        try p[0].sendRaw()
        sim.run(MS)
        #expect(p[1].got.count == 1 && p[2].got.count == 1)
        #expect(sw.lookup(try p[0].iface("eth0").mac) === (try sw.iface("Gi0/1")))
        try p[1].sendRaw(try p[0].iface("eth0").mac)
        sim.run(MS)
        #expect(p[0].got.count == 1)
        #expect(p[2].got.count == 1)
        #expect(sw.lookup(try p[1].iface("eth0").mac) === (try sw.iface("Gi0/2")))
    }

    @Test func switchAgesOutMacEntriesAfter300Seconds() throws {
        let sim = Sim()
        let sw = Switch(sim: sim, id: "SW1")
        let p = try star(sim, sw, ["A", "B"])
        try p[0].sendRaw()
        sim.run(MS)
        sim.run(301 * S)
        #expect(sw.lookup(try p[0].iface("eth0").mac) == nil)
    }

    @Test func staysBoundedInALayer2Loop() throws {
        let sim = Sim(logCapacity: 1000)
        let sw1 = Switch(sim: sim, id: "SW1")
        let sw2 = Switch(sim: sim, id: "SW2")
        _ = try Link(sim: sim, try sw1.iface("Gi0/1"), try sw2.iface("Gi0/1"))
        _ = try Link(sim: sim, try sw1.iface("Gi0/2"), try sw2.iface("Gi0/2"))
        let a = Probe(sim: sim, id: "A")
        _ = try Link(sim: sim, try a.iface("eth0"), try sw1.iface("Gi0/3"))
        try a.sendRaw()
        sim.run(10 * MS)
        #expect(sim.log.size == 1000)
        #expect(sim.log.total > 1000)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter L2Tests`
Expected: build FAIL — `cannot find 'Hub' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Devices/Hub.swift`:

```swift
/// Layer-1 repeater. Collisions are not modelled (links are full duplex).
final class Hub: Node {
    init(sim: Sim, id: String, ports: Int = 8) {
        super.init(sim: sim, id: id)
        for i in 1...ports { addInterface("p\(i)") }
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        for i in interfaces where i !== inIf && i.link != nil { i.send(frame) }
    }
}
```

`Sources/PacEngine/Devices/Switch.swift`:

```swift
let MAC_AGING_NS = 300 * S

/// Transparent learning bridge (802.1D without STP).
final class Switch: Node {
    private var table: [Mac: (iface: Interface, seen: Int)] = [:]

    init(sim: Sim, id: String, ports: Int = 8) {
        super.init(sim: sim, id: id)
        for i in 1...ports { addInterface("Gi0/\(i)") }
    }

    func lookup(_ mac: Mac) -> Interface? {
        guard let entry = table[mac] else { return nil }
        if sim.now - entry.seen > MAC_AGING_NS {
            table[mac] = nil
            return nil
        }
        return entry.iface
    }

    override func receive(_ frame: EthernetFrame, on inIf: Interface) {
        if !isGroupMac(frame.src) { table[frame.src] = (inIf, sim.now) }
        if !isGroupMac(frame.dst), let out = lookup(frame.dst) {
            if out !== inIf { out.send(frame) }
            return
        }
        for i in interfaces where i !== inIf && i.link != nil { i.send(frame) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 35 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Devices Tests/PacEngineTests/L2Tests.swift
git commit -m "feat(swift): add hub and learning switch"
```

---

### Task 7: Routing table

**Files:**
- Create: `Sources/PacEngine/L3/RoutingTable.swift`
- Test: `Tests/PacEngineTests/RoutingTests.swift`

**Interfaces:**
- Consumes: `Interface` (Task 5), address helpers (Task 3)
- Produces: `struct NextHop { let iface: Interface; let nextHop: UInt32 }`; `final class RoutingTable { init(interfaces: @escaping () -> [Interface]); func addStatic(_ cidr: String, _ nextHop: String) throws; func lookup(_ dst: UInt32) -> NextHop? }`

- [ ] **Step 1: Write the failing test**

`Tests/PacEngineTests/RoutingTests.swift`:

```swift
import Testing
@testable import PacEngine

private func setup() throws -> (sim: Sim, node: Probe, rt: RoutingTable) {
    let sim = Sim()
    let node = Probe(sim: sim, id: "R")
    node.addInterface("eth1")
    try node.iface("eth0").ipv4 = Cidr(addr: try parseIp("10.0.1.1"), prefix: 24)
    try node.iface("eth1").ipv4 = Cidr(addr: try parseIp("10.0.12.1"), prefix: 30)
    return (sim, node, RoutingTable(interfaces: { node.interfaces }))
}

private func hop(_ rt: RoutingTable, _ dst: String) throws -> String? {
    rt.lookup(try parseIp(dst)).map { "\($0.iface.name) via \(formatIp($0.nextHop))" }
}

@Suite struct RoutingTests {
    @Test func routesConnectedSubnetsDirectly() throws {
        let (_, _, rt) = try setup()
        #expect(try hop(rt, "10.0.1.50") == "eth0 via 10.0.1.50")
        #expect(try hop(rt, "10.0.12.2") == "eth1 via 10.0.12.2")
        #expect(try hop(rt, "8.8.8.8") == nil)
    }

    @Test func resolvesStaticRoutesLongestPrefixFirst() throws {
        let (_, _, rt) = try setup()
        try rt.addStatic("0.0.0.0/0", "10.0.1.254")
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        try rt.addStatic("10.0.2.128/25", "10.0.1.253")
        #expect(try hop(rt, "8.8.8.8") == "eth0 via 10.0.1.254")
        #expect(try hop(rt, "10.0.2.9") == "eth1 via 10.0.12.2")
        #expect(try hop(rt, "10.0.2.200") == "eth0 via 10.0.1.253")
    }

    @Test func rejectsStaticRoutesWhoseNextHopIsNotInAConnectedSubnet() throws {
        let (_, _, rt) = try setup()
        expectError("not in a connected subnet") { try rt.addStatic("172.16.0.0/16", "192.168.0.1") }
        #expect(try hop(rt, "172.16.5.5") == nil)
    }

    @Test func fallsBackToAShorterRouteWhenTheLongerOneLosesItsNextHop() throws {
        let (_, node, rt) = try setup()
        try rt.addStatic("0.0.0.0/0", "10.0.1.254")
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        try node.iface("eth1").up = false
        #expect(try hop(rt, "10.0.2.10") == "eth0 via 10.0.1.254")
    }

    @Test func dropsConnectedRoutesOfInterfacesThatAreDown() throws {
        let (_, node, rt) = try setup()
        try node.iface("eth0").up = false
        #expect(try hop(rt, "10.0.1.50") == nil)
    }

    @Test func replacesARouteWithTheSamePrefix() throws {
        let (_, _, rt) = try setup()
        try rt.addStatic("10.0.2.0/24", "10.0.12.2")
        try rt.addStatic("10.0.2.7/24", "10.0.1.9") // normalised to 10.0.2.0/24
        #expect(try hop(rt, "10.0.2.1") == "eth0 via 10.0.1.9")
    }

    @Test func rejectsMalformedInputWithoutChangingTheTable() throws {
        let (_, _, rt) = try setup()
        expectError("Invalid CIDR") { try rt.addStatic("10.0.2.0/33", "10.0.12.2") }
        expectError("Invalid IPv4") { try rt.addStatic("10.0.2.0/24", "10.0.12") }
        #expect(try hop(rt, "10.0.2.1") == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter RoutingTests`
Expected: build FAIL — `cannot find 'RoutingTable' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/L3/RoutingTable.swift`:

```swift
struct NextHop {
    let iface: Interface
    let nextHop: UInt32
}

private struct StaticRoute {
    let network: UInt32
    let prefix: Int
    let nextHop: UInt32
}

final class RoutingTable {
    private var statics: [StaticRoute] = []
    private let interfaces: () -> [Interface]

    init(interfaces: @escaping () -> [Interface]) {
        self.interfaces = interfaces
    }

    func addStatic(_ cidr: String, _ nextHop: String) throws {
        let c = try parseCidr(cidr)
        let route = StaticRoute(network: networkOf(c.addr, c.prefix), prefix: c.prefix, nextHop: try parseIp(nextHop))
        guard interfaces().contains(where: { i in i.ipv4.map { inSubnet(route.nextHop, $0.addr, $0.prefix) } ?? false }) else {
            throw EngineError("Next hop \(nextHop) is not in a connected subnet")
        }
        statics.removeAll { $0.network == route.network && $0.prefix == route.prefix }
        statics.append(route)
    }

    /// Longest-prefix match; on equal length a connected route wins.
    /// Static routes whose next hop is not currently reachable are skipped (as if withdrawn from the RIB).
    func lookup(_ dst: UInt32) -> NextHop? {
        let conn = connectedFor(dst)
        var best: NextHop?
        var bestPrefix = -1
        for r in statics where inSubnet(dst, r.network, r.prefix) && r.prefix > bestPrefix {
            guard let via = connectedFor(r.nextHop) else { continue }
            best = NextHop(iface: via.iface, nextHop: r.nextHop)
            bestPrefix = r.prefix
        }
        if let conn, conn.prefix >= bestPrefix { return NextHop(iface: conn.iface, nextHop: dst) }
        return best
    }

    private func connectedFor(_ ip: UInt32) -> (iface: Interface, prefix: Int)? {
        var best: (iface: Interface, prefix: Int)?
        for i in interfaces() {
            guard i.up, let c = i.ipv4, inSubnet(ip, c.addr, c.prefix), c.prefix > (best?.prefix ?? -1) else { continue }
            best = (i, c.prefix)
        }
        return best
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 42 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/L3/RoutingTable.swift Tests/PacEngineTests/RoutingTests.swift
git commit -m "feat(swift): add routing table with longest-prefix match"
```

---

### Task 8: IP stack — ARP, IPv4, ICMP, UDP; Host and Router

**Files:**
- Create: `Sources/PacEngine/L3/Arp.swift`, `Sources/PacEngine/L3/IpNode.swift`, `Sources/PacEngine/Devices/Host.swift`, `Sources/PacEngine/Devices/Router.swift`
- Modify: `Tests/PacEngineTests/TestUtils.swift` (append fixtures)
- Test: `Tests/PacEngineTests/IpTests.swift`

**Interfaces:**
- Consumes: Tasks 3–7
- Produces:
  - `ARP_CACHE_NS`, `ARP_RETRY_NS`, `ARP_RETRIES`, `ARP_PENDING_MAX`; `final class Arp { func lookup(_ ip: UInt32) -> Mac?; func send(_ iface:, nextHop:, _ packet:); func handle(_ arp:, on iface:) }`
  - `typealias IcmpListener = (Ipv4Packet, IcmpMessage) -> Void`; `typealias UdpHandler = (Ipv4Packet, UdpDatagram) -> Void`
  - `class IpNode: Node { lazy var arp; lazy var routes; var defaultTtl: UInt8; var forwarding: Bool; func setIp(_ ifName:, _ cidr:) throws; func setGateway(_ ip:) throws; func ownsIp(_:) -> Bool; func sourceFor(_:) -> UInt32?; @discardableResult func bindUdp(_ port: UInt16, _ handler:) throws -> () -> Void; @discardableResult func onIcmp(_ listener:) -> () -> Void; @discardableResult func sendPacket(_ dst: UInt32, _ payload: L4, ttl: UInt8? = nil) -> Bool; @discardableResult func sendUdp(_ dst:, srcPort:, dstPort:, data:, ttl: UInt8? = nil) -> Bool; func sendFrame(_ iface:, to:, etherType:, _ payload: L3); func icmpError(_ orig:, type:, code:) }`
  - `final class Host: IpNode { init(sim:id:) }` (`eth0`); `final class Router: IpNode { init(sim:id:ports: Int = 4) }` (`Gi0/0…`)
  - test utils: `IcmpRecorder` + `icmpSeen(_:)`, `Seen`, `lan()`, `routedPair()`

- [ ] **Step 1: Append fixtures to `Tests/PacEngineTests/TestUtils.swift`**

```swift
struct Seen: Equatable {
    let from: String
    let type: UInt8
    let code: UInt8
    let ttl: UInt8
}

final class IcmpRecorder {
    var seen: [Seen] = []
}

func icmpSeen(_ node: IpNode) -> IcmpRecorder {
    let recorder = IcmpRecorder()
    node.onIcmp { p, m in recorder.seen.append(Seen(from: formatIp(p.src), type: m.type, code: m.code, ttl: p.ttl)) }
    return recorder
}

func echoRequest(_ length: Int = 56) -> L4 {
    .icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: 9, seq: 1, data: [UInt8](repeating: 0, count: length)))
}

/// A (10.0.0.1/24) and B (10.0.0.2/24) on one switch.
func lan(_ sim: Sim = Sim()) throws -> (sim: Sim, sw: Switch, a: Host, b: Host) {
    let sw = Switch(sim: sim, id: "SW1")
    let a = Host(sim: sim, id: "A")
    let b = Host(sim: sim, id: "B")
    _ = try Link(sim: sim, try a.iface("eth0"), try sw.iface("Gi0/1"))
    _ = try Link(sim: sim, try b.iface("eth0"), try sw.iface("Gi0/2"))
    try a.setIp("eth0", "10.0.0.1/24")
    try b.setIp("eth0", "10.0.0.2/24")
    return (sim, sw, a, b)
}

/// H1 (10.0.1.10/24) — R1 (10.0.1.1 | 10.0.2.1) — H2 (10.0.2.10/24).
func routedPair(_ sim: Sim = Sim()) throws -> (sim: Sim, h1: Host, h2: Host, r1: Router) {
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let r1 = Router(sim: sim, id: "R1", ports: 2)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try h2.iface("eth0"))
    try r1.setIp("Gi0/0", "10.0.1.1/24")
    try r1.setIp("Gi0/1", "10.0.2.1/24")
    try h1.setIp("eth0", "10.0.1.10/24")
    try h1.setGateway("10.0.1.1")
    try h2.setIp("eth0", "10.0.2.10/24")
    try h2.setGateway("10.0.2.1")
    return (sim, h1, h2, r1)
}
```

- [ ] **Step 2: Write the failing test**

`Tests/PacEngineTests/IpTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct IpTests {
    // MARK: ARP + ICMP on a LAN

    @Test func resolvesMacsBothWaysAndAnswersEchoRequests() throws {
        let (sim, _, a, b) = try lan()
        let r = icmpSeen(a)
        #expect(a.sendPacket(try parseIp("10.0.0.2"), echoRequest()))
        sim.run(MS)
        #expect(a.arp.lookup(try parseIp("10.0.0.2")) == (try b.iface("eth0").mac))
        #expect(b.arp.lookup(try parseIp("10.0.0.1")) == (try a.iface("eth0").mac))
        #expect(r.seen == [Seen(from: "10.0.0.2", type: 0, code: 0, ttl: 64)])
    }

    @Test func reportsHostUnreachableToItselfAfterThreeUnansweredArpRequests() throws {
        let (sim, _, a, _) = try lan()
        let r = icmpSeen(a)
        a.sendPacket(try parseIp("10.0.0.99"), echoRequest())
        sim.run(2 * S)
        #expect(r.seen.isEmpty)
        sim.run(2 * S)
        #expect(r.seen == [Seen(from: "10.0.0.1", type: 3, code: 1, ttl: 64)])
        let arpTx = sim.log.all.filter {
            guard $0.kind == .tx, $0.node == "A", let f = $0.frame, case .arp = f.payload else { return false }
            return true
        }
        #expect(arpTx.count == 3)
        #expect(drops(sim, .arpTimeout) == 1)
    }

    @Test func answersClosedUdpPortsWithPortUnreachable() throws {
        let (sim, _, a, _) = try lan()
        let r = icmpSeen(a)
        a.sendUdp(try parseIp("10.0.0.2"), srcPort: 40000, dstPort: 9, data: [0, 0, 0, 0])
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.0.2", type: 3, code: 3, ttl: 64)])
    }

    @Test func deliversUdpToBoundPorts() throws {
        let (sim, _, a, b) = try lan()
        var got: [Int] = []
        try b.bindUdp(5000) { _, u in got.append(u.data.count) }
        expectError("in use") { try b.bindUdp(5000) { _, _ in } }
        a.sendUdp(try parseIp("10.0.0.2"), srcPort: 40000, dstPort: 5000, data: [UInt8](repeating: 0, count: 10))
        sim.run(MS)
        #expect(got == [10])
    }

    @Test func reportsFragmentationNeededForDfPacketsAboveTheMtu() throws {
        let (sim, _, a, _) = try lan()
        let r = icmpSeen(a)
        a.sendPacket(try parseIp("10.0.0.2"), echoRequest(1500))
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.0.1", type: 3, code: 4, ttl: 64)])
    }

    // MARK: routing through a router

    @Test func forwardsAndDecrementsTtl() throws {
        let (sim, h1, _, _) = try routedPair()
        let r = icmpSeen(h1)
        h1.sendPacket(try parseIp("10.0.2.10"), echoRequest())
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.2.10", type: 0, code: 0, ttl: 63)])
    }

    @Test func sendsTimeExceededWhenTtlRunsOut() throws {
        let (sim, h1, _, _) = try routedPair()
        let r = icmpSeen(h1)
        h1.sendPacket(try parseIp("10.0.2.10"), echoRequest(), ttl: 1)
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.1.1", type: 11, code: 0, ttl: 255)])
    }

    @Test func sendsNetUnreachableWhenTheRouterHasNoRoute() throws {
        let (sim, h1, _, _) = try routedPair()
        let r = icmpSeen(h1)
        h1.sendPacket(try parseIp("192.168.9.9"), echoRequest())
        sim.run(MS)
        #expect(r.seen == [Seen(from: "10.0.1.1", type: 3, code: 0, ttl: 255)])
    }

    @Test func refusesToOriginateWithoutARoute() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        #expect(!h.sendPacket(try parseIp("8.8.8.8"), echoRequest()))
    }

    // MARK: configuration validation

    @Test func rejectsBadAddressesAndKeepsTheOldOne() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        for bad in ["10.0.0.256/24", "10.0.0.1/33", "10.0.0.1", "abc"] {
            expectError("Invalid") { try h.setIp("eth0", bad) }
        }
        expectError("network or broadcast") { try h.setIp("eth0", "10.0.0.0/24") }
        expectError("network or broadcast") { try h.setIp("eth0", "10.0.0.255/24") }
        #expect(try h.iface("eth0").ipv4 == Cidr(addr: try parseIp("10.0.0.1"), prefix: 24))
    }

    @Test func rejectsOverlappingSubnetsOnOneNode() throws {
        let (_, _, _, r1) = try routedPair()
        expectError("overlaps") { try r1.setIp("Gi0/1", "10.0.1.2/24") }
        #expect(try r1.iface("Gi0/1").ipv4?.addr == (try parseIp("10.0.2.1")))
    }

    @Test func rejectsAGatewayOutsideConnectedSubnets() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        expectError("not in a connected subnet") { try h.setGateway("10.0.1.1") }
        #expect(h.routes.lookup(try parseIp("8.8.8.8")) == nil)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `scripts/test.sh --filter IpTests`
Expected: build FAIL — `cannot find type 'IpNode' in scope`.

- [ ] **Step 4: Implement**

`Sources/PacEngine/L3/Arp.swift`:

```swift
let ARP_CACHE_NS = 300 * S
let ARP_RETRY_NS = 1 * S
let ARP_RETRIES = 3
let ARP_PENDING_MAX = 3

private final class Pending {
    let iface: Interface
    var packets: [Ipv4Packet]
    var tries = 0
    var timer: SimTimer?

    init(iface: Interface, packets: [Ipv4Packet]) {
        self.iface = iface
        self.packets = packets
    }
}

final class Arp {
    unowned let node: IpNode
    private var cache: [UInt32: (mac: Mac, iface: Interface, expiresAt: Int)] = [:]
    private var pending: [UInt32: Pending] = [:]

    init(node: IpNode) {
        self.node = node
    }

    func lookup(_ ip: UInt32) -> Mac? {
        guard let entry = cache[ip] else { return nil }
        if node.sim.now >= entry.expiresAt {
            cache[ip] = nil
            return nil
        }
        return entry.mac
    }

    /// Sends `packet` to `nextHop` on `iface`, resolving its MAC first if needed.
    func send(_ iface: Interface, nextHop: UInt32, _ packet: Ipv4Packet) {
        if let mac = lookup(nextHop) {
            return node.sendFrame(iface, to: mac, etherType: ETHERTYPE_IPV4, .ipv4(packet))
        }
        if let waiting = pending[nextHop] {
            if waiting.packets.count < ARP_PENDING_MAX {
                waiting.packets.append(packet)
            } else {
                node.sim.emit(.drop, node: node.id, iface: iface.name, packet: packet, reason: .arpPendingFull)
            }
            return
        }
        let fresh = Pending(iface: iface, packets: [packet])
        pending[nextHop] = fresh
        request(nextHop, fresh)
    }

    func handle(_ arp: ArpPacket, on iface: Interface) {
        let own = iface.ipv4?.addr
        let forUs = own != nil && arp.targetIp == own
        let known = cache[arp.senderIp] != nil
        if forUs || known { cache[arp.senderIp] = (arp.senderMac, iface, node.sim.now + ARP_CACHE_NS) }
        if forUs, arp.op == 1, let own {
            node.sendFrame(iface, to: arp.senderMac, etherType: ETHERTYPE_ARP,
                           .arp(ArpPacket(op: 2, senderMac: iface.mac, senderIp: own, targetMac: arp.senderMac, targetIp: arp.senderIp)))
        }
        if forUs || known, let waiting = pending.removeValue(forKey: arp.senderIp) {
            waiting.timer?.cancel()
            for p in waiting.packets { node.sendFrame(waiting.iface, to: arp.senderMac, etherType: ETHERTYPE_IPV4, .ipv4(p)) }
        }
    }

    private func request(_ ip: UInt32, _ p: Pending) {
        p.tries += 1
        node.sendFrame(p.iface, to: BROADCAST_MAC, etherType: ETHERTYPE_ARP,
                       .arp(ArpPacket(op: 1, senderMac: p.iface.mac, senderIp: p.iface.ipv4?.addr ?? 0, targetMac: "00:00:00:00:00:00", targetIp: ip)))
        p.timer = node.sim.sched.after(ARP_RETRY_NS) { [self] in
            if p.tries < ARP_RETRIES { return request(ip, p) }
            pending[ip] = nil
            for packet in p.packets {
                node.sim.emit(.drop, node: node.id, iface: p.iface.name, packet: packet, reason: .arpTimeout)
                node.icmpError(packet, type: ICMP_DEST_UNREACH, code: UNREACH_HOST)
            }
        }
    }
}
```

`Sources/PacEngine/L3/IpNode.swift`:

```swift
typealias IcmpListener = (Ipv4Packet, IcmpMessage) -> Void
typealias UdpHandler = (Ipv4Packet, UdpDatagram) -> Void

/// A node with an IPv4 stack: ARP, routing, ICMP and UDP.
class IpNode: Node {
    private(set) lazy var arp = Arp(node: self)
    private(set) lazy var routes = RoutingTable(interfaces: { [unowned self] in self.interfaces })
    var defaultTtl: UInt8 = 64
    var forwarding = false
    private var ipId: UInt16 = 0
    private var udp: [UInt16: UdpHandler] = [:]
    /// Ordered (not a dictionary): listener order must be deterministic.
    private var icmpListeners: [(token: Int, listener: IcmpListener)] = []
    private var nextToken = 0

    func setIp(_ ifName: String, _ cidr: String) throws {
        let iface = try self.iface(ifName)
        let c = try parseCidr(cidr)
        if c.prefix < 31 && (c.addr == networkOf(c.addr, c.prefix) || c.addr == broadcastOf(c.addr, c.prefix)) {
            throw EngineError("\(cidr) is a network or broadcast address")
        }
        for other in interfaces where other !== iface {
            if let o = other.ipv4, inSubnet(c.addr, o.addr, min(c.prefix, o.prefix)) {
                throw EngineError("\(cidr) overlaps with \(other.name)")
            }
        }
        iface.ipv4 = c
    }

    func setGateway(_ ip: String) throws {
        try routes.addStatic("0.0.0.0/0", ip)
    }

    func ownsIp(_ ip: UInt32) -> Bool {
        interfaces.contains { $0.ipv4?.addr == ip }
    }

    /// Source address this node would use to reach `dst`, if routable.
    func sourceFor(_ dst: UInt32) -> UInt32? {
        ownsIp(dst) ? dst : routes.lookup(dst)?.iface.ipv4?.addr
    }

    @discardableResult
    func bindUdp(_ port: UInt16, _ handler: @escaping UdpHandler) throws -> () -> Void {
        guard udp[port] == nil else { throw EngineError("UDP port \(port) already in use") }
        udp[port] = handler
        return { [weak self] in self?.udp[port] = nil }
    }

    @discardableResult
    func onIcmp(_ listener: @escaping IcmpListener) -> () -> Void {
        nextToken += 1
        let token = nextToken
        icmpListeners.append((token, listener))
        return { [weak self] in self?.icmpListeners.removeAll { $0.token == token } }
    }

    /// Originates a packet. Returns false when there is no route to `dst`.
    @discardableResult
    func sendPacket(_ dst: UInt32, _ payload: L4, ttl: UInt8? = nil) -> Bool {
        guard let src = sourceFor(dst) else { return false }
        output(makeIpv4(src: src, dst: dst, ttl: ttl ?? defaultTtl, id: nextIpId(), payload: payload))
        return true
    }

    @discardableResult
    func sendUdp(_ dst: UInt32, srcPort: UInt16, dstPort: UInt16, data: [UInt8], ttl: UInt8? = nil) -> Bool {
        sendPacket(dst, .udp(makeUdp(srcPort: srcPort, dstPort: dstPort, data: data)), ttl: ttl)
    }

    func sendFrame(_ iface: Interface, to dst: Mac, etherType: UInt16, _ payload: L3) {
        iface.send(EthernetFrame(id: sim.nextId(), src: iface.mac, dst: dst, etherType: etherType, payload: payload))
    }

    /// Sends an ICMP error about `orig` back to its source (never about ICMP errors).
    func icmpError(_ orig: Ipv4Packet, type: UInt8, code: UInt8) {
        if case .icmp(let m) = orig.payload, m.type != ICMP_ECHO_REQUEST && m.type != ICMP_ECHO_REPLY { return }
        if orig.dst == BROADCAST_IP || orig.src == 0 { return }
        guard let src = sourceFor(orig.src) else { return }
        let quote = serializeHeader(orig) + serializeL4(orig).prefix(8)
        output(makeIpv4(src: src, dst: orig.src, ttl: defaultTtl, id: nextIpId(),
                        payload: .icmp(makeIcmp(type: type, code: code, id: 0, seq: 0, data: quote))))
    }

    override func receive(_ frame: EthernetFrame, on iface: Interface) {
        guard frame.dst == iface.mac || frame.dst == BROADCAST_MAC else { return }
        switch frame.payload {
        case .arp(let a): arp.handle(a, on: iface)
        case .ipv4(let p): input(p, on: iface)
        }
    }

    private func input(_ p: Ipv4Packet, on iface: Interface) {
        let subnetBroadcast = iface.ipv4.map { p.dst == broadcastOf($0.addr, $0.prefix) } ?? false
        if ownsIp(p.dst) || p.dst == BROADCAST_IP || subnetBroadcast { return deliver(p) }
        guard forwarding else { return }
        if p.ttl <= 1 {
            sim.emit(.drop, node: id, iface: iface.name, packet: p, reason: .ttlExpired)
            return icmpError(p, type: ICMP_TIME_EXCEEDED, code: 0)
        }
        output(withTtl(p, p.ttl - 1))
    }

    private func output(_ p: Ipv4Packet) {
        if ownsIp(p.dst) {
            sim.sched.after(0) { [self] in deliver(p) }
            return
        }
        guard let hop = routes.lookup(p.dst) else {
            sim.emit(.drop, node: id, packet: p, reason: .noRoute)
            return icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_NET)
        }
        if p.size > hop.iface.mtu {
            // ponytail: no IPv4 fragmentation; non-DF oversize packets are dropped
            sim.emit(.drop, node: id, iface: hop.iface.name, packet: p, reason: .mtuExceeded)
            if p.dontFragment { icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_FRAG_NEEDED) }
            return
        }
        arp.send(hop.iface, nextHop: hop.nextHop, p)
    }

    private func deliver(_ p: Ipv4Packet) {
        switch p.payload {
        case .icmp(let m):
            if m.type == ICMP_ECHO_REQUEST && p.dst != BROADCAST_IP {
                // Reply from the address that was pinged, like Linux and IOS do.
                output(makeIpv4(src: p.dst, dst: p.src, ttl: defaultTtl, id: nextIpId(),
                                payload: .icmp(makeIcmp(type: ICMP_ECHO_REPLY, code: 0, id: m.id, seq: m.seq, data: m.data))))
            }
            for entry in icmpListeners { entry.listener(p, m) }
        case .udp(let u):
            if let handler = udp[u.dstPort] {
                handler(p, u)
            } else if p.dst != BROADCAST_IP {
                icmpError(p, type: ICMP_DEST_UNREACH, code: UNREACH_PORT)
            }
        }
    }

    private func nextIpId() -> UInt16 {
        ipId &+= 1
        return ipId
    }
}
```

`Sources/PacEngine/Devices/Host.swift`:

```swift
final class Host: IpNode {
    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("eth0")
    }
}
```

`Sources/PacEngine/Devices/Router.swift`:

```swift
final class Router: IpNode {
    init(sim: Sim, id: String, ports: Int = 4) {
        super.init(sim: sim, id: id)
        forwarding = true
        defaultTtl = 255
        for i in 0..<ports { addInterface("Gi0/\(i)") }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: 54 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/PacEngine Tests/PacEngineTests
git commit -m "feat(swift): add IPv4 stack with ARP, ICMP, UDP, hosts and routers"
```

---

### Task 9: Ping

**Files:**
- Create: `Sources/PacEngine/Apps/Ping.swift`
- Test: `Tests/PacEngineTests/PingTests.swift`

**Interfaces:**
- Consumes: `IpNode.sendPacket`, `IpNode.onIcmp` (Task 8)
- Produces: `struct PingOptions { var count = 4; var intervalNs = 1 * S; var timeoutNs = 10 * S; var size = 56; var ttl: Int? = nil }`; `struct PingReply: Equatable { seq; from: String; ttl: Int; rttNs: Int }`; `struct PingError: Equatable { seq; from; type: Int; code: Int }`; `struct PingResult { transmitted; received; replies; errors; lines: [String]; done }`; `final class Ping { init(node: IpNode, target: String, options: PingOptions = .init()) throws; private(set) var result: PingResult; func stop() }`

- [ ] **Step 1: Write the failing test**

`Tests/PacEngineTests/PingTests.swift`:

```swift
import Testing
@testable import PacEngine

/// Two hosts on a 10 Mb/s, 1 ms cable.
private func slowPair() throws -> (sim: Sim, a: Host, b: Host) {
    let sim = Sim()
    let a = Host(sim: sim, id: "A")
    let b = Host(sim: sim, id: "B")
    _ = try Link(sim: sim, try a.iface("eth0"), try b.iface("eth0"), LinkOptions(bandwidthBps: 10e6, propDelayNs: 1 * MS))
    try a.setIp("eth0", "10.0.0.1/24")
    try b.setIp("eth0", "10.0.0.2/24")
    return (sim, a, b)
}

@Suite struct PingTests {
    @Test func measuresRttExactlyArpPlusEchoFirstThenEchoOnly() throws {
        let (sim, a, _) = try slowPair()
        let p = try Ping(node: a, target: "10.0.0.2", options: PingOptions(count: 2))
        sim.run(12 * S)
        #expect(p.result.done)
        #expect(p.result.received == 2)
        // ARP 84 B wire @10 Mb/s = 67.2 µs, echo 122 B = 97.6 µs, +1 ms each way
        #expect(p.result.replies.map { $0.rttNs } == [4_329_600, 2_195_200])
        #expect(p.result.lines == [
            "PING 10.0.0.2 (10.0.0.2) 56(84) bytes of data.",
            "64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=4.330 ms",
            "64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=2.195 ms",
            "--- 10.0.0.2 ping statistics ---",
            "2 packets transmitted, 2 received, 0% packet loss",
        ])
    }

    @Test func pingsItsOwnAddressThroughLoopback() throws {
        let (sim, a, _) = try slowPair()
        let p = try Ping(node: a, target: "10.0.0.1", options: PingOptions(count: 1))
        sim.run(1 * MS)
        #expect(p.result.replies == [PingReply(seq: 1, from: "10.0.0.1", ttl: 64, rttNs: 0)])
        #expect(p.result.done)
        #expect(sim.log.all.filter { $0.kind == .tx }.isEmpty)
    }

    @Test func getsAReplyFromARoutersFarSideInterface() throws {
        let (sim, h1, _, _) = try routedPair()
        let p = try Ping(node: h1, target: "10.0.2.1", options: PingOptions(count: 1))
        sim.run(1 * S)
        #expect(p.result.replies.map { "\($0.from) \($0.ttl)" } == ["10.0.2.1 255"])
    }

    @Test func reportsTtlExceeded() throws {
        let (sim, h1, _, _) = try routedPair()
        let p = try Ping(node: h1, target: "10.0.2.10", options: PingOptions(count: 1, ttl: 1))
        sim.run(1 * S)
        #expect(p.result.errors == [PingError(seq: 1, from: "10.0.1.1", type: 11, code: 0)])
        #expect(p.result.lines.contains("From 10.0.1.1 icmp_seq=1 Time to live exceeded"))
    }

    @Test func reportsDestinationHostUnreachableFromAHostWithNoCable() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        let p = try Ping(node: h, target: "10.0.0.2", options: PingOptions(count: 1))
        sim.run(11 * S)
        #expect(p.result.received == 0)
        #expect(p.result.lines.contains("From 10.0.0.1 icmp_seq=1 Destination Host Unreachable"))
        #expect(p.result.lines.last == "1 packets transmitted, 0 received, +1 errors, 100% packet loss")
        #expect(drops(sim, .noLink) == 3)
    }

    @Test func failsFastWithNoRoute() throws {
        let sim = Sim()
        let h = Host(sim: sim, id: "H")
        try h.setIp("eth0", "10.0.0.1/24")
        let p = try Ping(node: h, target: "8.8.8.8")
        sim.run(1)
        #expect(p.result.done)
        #expect(p.result.transmitted == 0)
        #expect(p.result.lines[1] == "ping: connect: Network is unreachable")
    }

    @Test func stopEndsEarlyWithStatistics() throws {
        let (sim, a, _) = try slowPair()
        let p = try Ping(node: a, target: "10.0.0.2", options: PingOptions(count: 100))
        sim.run(1500 * MS)
        p.stop()
        #expect(p.result.done)
        #expect(p.result.transmitted == 2)
        #expect(p.result.lines.last == "2 packets transmitted, 2 received, 0% packet loss")
    }

    @Test func rejectsAnInvalidTarget() throws {
        let (_, a, _) = try slowPair()
        expectError("Invalid IPv4") { _ = try Ping(node: a, target: "10.0.0.300") }
    }

    @Test func rejectsInvalidOptionsSynchronously() throws {
        let (_, a, _) = try slowPair()
        let invalid = [PingOptions(size: -1), PingOptions(size: 65508), PingOptions(ttl: 0), PingOptions(ttl: 256),
                       PingOptions(count: 0), PingOptions(intervalNs: 0), PingOptions(timeoutNs: 0)]
        for opts in invalid {
            expectError("Invalid ping option") { _ = try Ping(node: a, target: "10.0.0.2", options: opts) }
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter PingTests`
Expected: build FAIL — `cannot find 'Ping' in scope`.

- [ ] **Step 3: Implement**

`Sources/PacEngine/Apps/Ping.swift`:

```swift
import Foundation

struct PingOptions: Sendable {
    var count = 4
    var intervalNs = 1 * S
    /// How long to wait after the last request before giving up.
    var timeoutNs = 10 * S
    var size = 56
    var ttl: Int? = nil
}

struct PingReply: Equatable, Sendable {
    let seq: Int
    let from: String
    let ttl: Int
    let rttNs: Int
}

struct PingError: Equatable, Sendable {
    let seq: Int
    let from: String
    let type: Int
    let code: Int
}

struct PingResult: Sendable {
    var transmitted = 0
    var received = 0
    var replies: [PingReply] = []
    var errors: [PingError] = []
    var lines: [String] = []
    var done = false
}

private let ERROR_TEXT: [String: String] = [
    "3/0": "Destination Net Unreachable",
    "3/1": "Destination Host Unreachable",
    "3/3": "Destination Port Unreachable",
    "3/4": "Frag needed and DF set",
    "11/0": "Time to live exceeded",
]

func formatMs(_ ns: Int) -> String {
    String(format: "%.3f", Double(ns) / Double(MS))
}

/// Linux-style ping. Output lines mimic iputils. Keeps itself alive (timers, listener) until finished.
final class Ping {
    private(set) var result = PingResult()
    private let node: IpNode
    private let target: String
    private let dst: UInt32
    private let opts: PingOptions
    private let id: UInt16
    private var sentAt: [Int: Int] = [:]
    private var timers: [SimTimer] = []
    private var unlisten: () -> Void = {}

    init(node: IpNode, target: String, options: PingOptions = PingOptions()) throws {
        let o = options
        guard o.count >= 1, o.intervalNs > 0, o.timeoutNs > 0, (0...65507).contains(o.size),
              o.ttl.map({ (1...255).contains($0) }) ?? true else {
            throw EngineError("Invalid ping option: \(options)")
        }
        self.node = node
        self.target = target
        opts = o
        dst = try parseIp(target)
        id = UInt16(node.sim.rng.int(0x10000))
        result.lines = ["PING \(target) (\(target)) \(o.size)(\(o.size + 28)) bytes of data."]
        unlisten = node.onIcmp { [self] p, m in onIcmp(p, m) }
        for seq in 1...o.count {
            timers.append(node.sim.sched.after((seq - 1) * o.intervalNs) { [self] in send(seq) })
        }
        timers.append(node.sim.sched.after((o.count - 1) * o.intervalNs + o.timeoutNs) { [self] in finish(stats: true) })
    }

    func stop() {
        finish(stats: true)
    }

    private func send(_ seq: Int) {
        let payload = L4.icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: id, seq: UInt16(truncatingIfNeeded: seq),
                                       data: [UInt8](repeating: 0, count: opts.size)))
        sentAt[seq] = node.sim.now
        guard node.sendPacket(dst, payload, ttl: opts.ttl.map { UInt8($0) }) else {
            sentAt[seq] = nil
            result.lines.append("ping: connect: Network is unreachable")
            return finish(stats: false)
        }
        result.transmitted += 1
    }

    private func onIcmp(_ p: Ipv4Packet, _ m: IcmpMessage) {
        if m.type == ICMP_ECHO_REPLY {
            let seq = Int(m.seq)
            guard m.id == id, let at = sentAt.removeValue(forKey: seq) else { return }
            let rtt = node.sim.now - at
            result.received += 1
            result.replies.append(PingReply(seq: seq, from: formatIp(p.src), ttl: Int(p.ttl), rttNs: rtt))
            result.lines.append("\(m.data.count + 8) bytes from \(formatIp(p.src)): icmp_seq=\(seq) ttl=\(p.ttl) time=\(formatMs(rtt)) ms")
            return settleIfComplete()
        }
        guard m.type == ICMP_DEST_UNREACH || m.type == ICMP_TIME_EXCEEDED else { return }
        // Quoted datagram: our IPv4 header (20 B) + first 8 B of our echo request.
        let q = m.data
        guard q.count >= 28, q[20] == ICMP_ECHO_REQUEST, UInt16(q[24]) << 8 | UInt16(q[25]) == id else { return }
        let seq = Int(UInt16(q[26]) << 8 | UInt16(q[27]))
        sentAt[seq] = nil
        result.errors.append(PingError(seq: seq, from: formatIp(p.src), type: Int(m.type), code: Int(m.code)))
        let text = ERROR_TEXT["\(m.type)/\(m.code)"] ?? "ICMP type \(m.type) code \(m.code)"
        result.lines.append("From \(formatIp(p.src)) icmp_seq=\(seq) \(text)")
        settleIfComplete()
    }

    private func settleIfComplete() {
        if result.transmitted == opts.count && sentAt.isEmpty { finish(stats: true) }
    }

    private func finish(stats: Bool) {
        guard !result.done else { return }
        result.done = true
        timers.forEach { $0.cancel() }
        unlisten()
        guard stats else { return }
        let lost = result.transmitted - result.received
        let loss = result.transmitted == 0 ? 0 : Int((Double(lost) / Double(result.transmitted) * 100).rounded())
        let errors = result.errors.isEmpty ? "" : "+\(result.errors.count) errors, "
        result.lines.append("--- \(target) ping statistics ---")
        result.lines.append("\(result.transmitted) packets transmitted, \(result.received) received, \(errors)\(loss)% packet loss")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: 63 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/PacEngine/Apps/Ping.swift Tests/PacEngineTests/PingTests.swift
git commit -m "feat(swift): add ping application"
```

---

### Task 10: Traceroute and determinism

**Files:**
- Create: `Sources/PacEngine/Apps/Traceroute.swift`
- Modify: `Tests/PacEngineTests/TestUtils.swift` (append `twoRouters`)
- Test: `Tests/PacEngineTests/TracerouteTests.swift`

**Interfaces:**
- Consumes: `IpNode.sendUdp`, `IpNode.onIcmp` (Task 8), `formatMs` (Task 9)
- Produces: `struct TracerouteOptions { var maxHops = 30; var probes = 3; var waitNs = 5 * S; var firstPort = 33434 }`; `struct TraceProbe: Equatable { var from: String?; var rttNs: Int?; var note: String? }`; `struct TraceHop: Equatable { let ttl: Int; var probes: [TraceProbe] }`; `struct TracerouteResult { hops; reached; done; lines }`; `final class Traceroute { init(node:target:options:) throws; private(set) var result; func stop() }`; test util `twoRouters(_ sim: Sim = Sim(), lastLink: LinkOptions = .init())`

- [ ] **Step 1: Append the fixture to `Tests/PacEngineTests/TestUtils.swift`**

```swift
/// H1 10.0.1.10 — R1 (10.0.1.1 | 10.0.12.1/30) — R2 (10.0.12.2/30 | 10.0.2.1) — H2 10.0.2.10.
func twoRouters(_ sim: Sim = Sim(), lastLink: LinkOptions = LinkOptions()) throws
    -> (sim: Sim, h1: Host, h2: Host, r1: Router, r2: Router) {
    let h1 = Host(sim: sim, id: "H1")
    let h2 = Host(sim: sim, id: "H2")
    let r1 = Router(sim: sim, id: "R1", ports: 2)
    let r2 = Router(sim: sim, id: "R2", ports: 2)
    _ = try Link(sim: sim, try h1.iface("eth0"), try r1.iface("Gi0/0"))
    _ = try Link(sim: sim, try r1.iface("Gi0/1"), try r2.iface("Gi0/0"))
    _ = try Link(sim: sim, try r2.iface("Gi0/1"), try h2.iface("eth0"), lastLink)
    try r1.setIp("Gi0/0", "10.0.1.1/24")
    try r1.setIp("Gi0/1", "10.0.12.1/30")
    try r2.setIp("Gi0/0", "10.0.12.2/30")
    try r2.setIp("Gi0/1", "10.0.2.1/24")
    try r1.routes.addStatic("10.0.2.0/24", "10.0.12.2")
    try r2.routes.addStatic("10.0.1.0/24", "10.0.12.1")
    try h1.setIp("eth0", "10.0.1.10/24")
    try h1.setGateway("10.0.1.1")
    try h2.setIp("eth0", "10.0.2.10/24")
    try h2.setGateway("10.0.2.1")
    return (sim, h1, h2, r1, r2)
}
```

- [ ] **Step 2: Write the failing test**

`Tests/PacEngineTests/TracerouteTests.swift`:

```swift
import Testing
@testable import PacEngine

@Suite struct TracerouteTests {
    @Test func listsEveryHopUpToTheDestination() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        let t = try Traceroute(node: h1, target: "10.0.2.10")
        sim.run(30 * S)
        #expect(t.result.done)
        #expect(t.result.reached)
        #expect(t.result.hops.map { $0.probes.map { $0.from ?? "*" } } == [
            ["10.0.1.1", "10.0.1.1", "10.0.1.1"],
            ["10.0.12.2", "10.0.12.2", "10.0.12.2"],
            ["10.0.2.10", "10.0.2.10", "10.0.2.10"],
        ])
        #expect(t.result.lines[0] == "traceroute to 10.0.2.10 (10.0.2.10), 30 hops max, 60 byte packets")
        #expect(t.result.lines[1].wholeMatch(of: /^ 1  10\.0\.1\.1 \(10\.0\.1\.1\)  \d+\.\d{3} ms  \d+\.\d{3} ms  \d+\.\d{3} ms$/) != nil)
    }

    @Test func marksUnreachableNetworksWithBangNAndStops() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        let t = try Traceroute(node: h1, target: "10.0.9.9")
        sim.run(30 * S)
        #expect(t.result.hops.count == 2)
        #expect(t.result.reached)
        #expect(t.result.lines[2].firstMatch(of: /^ 2  10\.0\.1\.1 \(10\.0\.1\.1\)  \d+\.\d{3} ms !N/) != nil)
    }

    @Test func printsStarsForUnansweredProbesAndHonoursMaxHops() throws {
        let (sim, h1, _, _, _) = try twoRouters(lastLink: LinkOptions(lossRate: 1))
        let t = try Traceroute(node: h1, target: "10.0.2.10", options: TracerouteOptions(maxHops: 3, waitNs: 1 * S))
        sim.run(30 * S)
        #expect(t.result.done)
        #expect(!t.result.reached)
        #expect(t.result.lines[3] == " 3  * * *")
    }

    @Test func pingAcrossTwoRoutersSeesTtl62() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        let p = try Ping(node: h1, target: "10.0.2.10", options: PingOptions(count: 1))
        sim.run(1 * S)
        #expect(p.result.replies.first?.ttl == 62)
    }

    @Test func keepsConcurrentTraceroutesFromTheSameNodeApart() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        // Resolve the gateway first: 6 simultaneous probes would overflow the 3-packet ARP queue.
        _ = try Ping(node: h1, target: "10.0.1.1", options: PingOptions(count: 1))
        sim.run(1 * S)
        let good = try Traceroute(node: h1, target: "10.0.2.10")
        let bad = try Traceroute(node: h1, target: "10.0.9.9")
        sim.run(60 * S)
        #expect(good.result.hops.map { $0.probes[0].from } == ["10.0.1.1", "10.0.12.2", "10.0.2.10"])
        #expect(bad.result.hops.map { $0.probes[0].from } == ["10.0.1.1", "10.0.1.1"])
        #expect(bad.result.lines[2].contains("!N"))
    }

    @Test func rejectsInvalidOptionsSynchronously() throws {
        let (_, h1, _, _, _) = try twoRouters()
        let invalid = [TracerouteOptions(maxHops: 0), TracerouteOptions(maxHops: 256), TracerouteOptions(probes: 0),
                       TracerouteOptions(waitNs: 0), TracerouteOptions(firstPort: 70000)]
        for opts in invalid {
            expectError("Invalid traceroute option") { _ = try Traceroute(node: h1, target: "10.0.2.10", options: opts) }
        }
    }

    @Test func sameSeedAndTopologyProduceAnIdenticalEventLog() throws {
        func run(_ seed: UInt32) throws -> [String] {
            let net = try twoRouters(Sim(seed: seed))
            _ = try Ping(node: net.h1, target: "10.0.2.10", options: PingOptions(count: 3))
            _ = try Traceroute(node: net.h1, target: "10.0.2.10")
            net.sim.run(30 * S)
            return net.sim.log.all.map { "\($0.time) \($0.kind) \($0.node) \($0.iface ?? "") \($0.frame?.id ?? 0) \($0.reason?.rawValue ?? "")" }
        }
        let first = try run(5)
        #expect(first.count > 50)
        #expect(try run(5) == first)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `scripts/test.sh --filter TracerouteTests`
Expected: build FAIL — `cannot find 'Traceroute' in scope`.

- [ ] **Step 4: Implement**

`Sources/PacEngine/Apps/Traceroute.swift`:

```swift
struct TracerouteOptions: Sendable {
    var maxHops = 30
    var probes = 3
    var waitNs = 5 * S
    var firstPort = 33434
}

struct TraceProbe: Equatable, Sendable {
    var from: String?
    var rttNs: Int?
    var note: String?
}

struct TraceHop: Equatable, Sendable {
    let ttl: Int
    var probes: [TraceProbe]
}

struct TracerouteResult: Sendable {
    var hops: [TraceHop] = []
    var reached = false
    var done = false
    var lines: [String] = []
}

private let NOTES: [UInt8: String] = [0: "!N", 1: "!H", 4: "!F"]

private func formatHop(_ hop: TraceHop) -> String {
    var line = (hop.ttl < 10 ? " " : "") + "\(hop.ttl) "
    var last: String?
    for p in hop.probes {
        guard let from = p.from, let rtt = p.rttNs else {
            line += " *"
            continue
        }
        if from != last {
            line += " \(from) (\(from))"
            last = from
        }
        line += "  \(formatMs(rtt)) ms" + (p.note.map { " \($0)" } ?? "")
    }
    return line
}

private final class InFlight {
    let hopIndex: Int
    var sent: [UInt16: (index: Int, at: Int)] = [:]
    var pending: Int
    var timer: SimTimer?

    init(hopIndex: Int, pending: Int) {
        self.hopIndex = hopIndex
        self.pending = pending
    }
}

/// Linux-style UDP traceroute: `probes` probes per TTL, one hop at a time. Keeps itself alive until finished.
final class Traceroute {
    private(set) var result = TracerouteResult()
    private let node: IpNode
    private let dst: UInt32
    private let opts: TracerouteOptions
    private let srcPort: UInt16
    private var port: Int
    private var current: InFlight?
    private var unlisten: () -> Void = {}

    init(node: IpNode, target: String, options: TracerouteOptions = TracerouteOptions()) throws {
        let o = options
        guard (1...255).contains(o.maxHops), o.probes >= 1, o.waitNs > 0, o.firstPort >= 1,
              o.firstPort + o.maxHops * o.probes <= 0x10000 else {
            throw EngineError("Invalid traceroute option: \(options)")
        }
        self.node = node
        opts = o
        dst = try parseIp(target)
        srcPort = UInt16(33000 + node.sim.rng.int(10000))
        port = o.firstPort
        result.lines = ["traceroute to \(target) (\(target)), \(o.maxHops) hops max, 60 byte packets"]
        unlisten = node.onIcmp { [self] p, m in onIcmp(p, m) }
        node.sim.sched.after(0) { [self] in sendHop(1) }
    }

    func stop() {
        finish()
    }

    private func sendHop(_ ttl: Int) {
        result.hops.append(TraceHop(ttl: ttl, probes: Array(repeating: TraceProbe(), count: opts.probes)))
        let flight = InFlight(hopIndex: result.hops.count - 1, pending: opts.probes)
        current = flight
        for i in 0..<opts.probes {
            let dport = UInt16(port)
            port += 1
            flight.sent[dport] = (i, node.sim.now)
            guard node.sendUdp(dst, srcPort: srcPort, dstPort: dport, data: [UInt8](repeating: 0, count: 32), ttl: UInt8(ttl)) else {
                result.lines.append("connect: Network is unreachable")
                return finish()
            }
        }
        flight.timer = node.sim.sched.after(opts.waitNs) { [self] in closeHop() }
    }

    private func closeHop() {
        guard let flight = current else { return }
        flight.timer?.cancel()
        current = nil
        let hop = result.hops[flight.hopIndex]
        result.lines.append(formatHop(hop))
        if result.reached || hop.ttl >= opts.maxHops {
            finish()
        } else {
            sendHop(hop.ttl + 1)
        }
    }

    private func onIcmp(_ p: Ipv4Packet, _ m: IcmpMessage) {
        guard let flight = current, m.type == ICMP_TIME_EXCEEDED || m.type == ICMP_DEST_UNREACH else { return }
        // Quoted datagram: original IPv4 header (20 B) + UDP header (8 B). Only our own probes count.
        let q = m.data
        guard q.count >= 28, q[9] == IPPROTO_UDP else { return }
        let quotedDst = UInt32(q[16]) << 24 | UInt32(q[17]) << 16 | UInt32(q[18]) << 8 | UInt32(q[19])
        let quotedSrcPort = UInt16(q[20]) << 8 | UInt16(q[21])
        guard quotedDst == dst, quotedSrcPort == srcPort else { return }
        let dport = UInt16(q[22]) << 8 | UInt16(q[23])
        guard let probe = flight.sent.removeValue(forKey: dport) else { return }
        let note = m.type == ICMP_DEST_UNREACH && m.code != UNREACH_PORT ? NOTES[m.code] ?? "!<\(m.code)>" : nil
        result.hops[flight.hopIndex].probes[probe.index] = TraceProbe(from: formatIp(p.src), rttNs: node.sim.now - probe.at, note: note)
        if m.type == ICMP_DEST_UNREACH { result.reached = true }
        flight.pending -= 1
        if flight.pending == 0 { closeHop() }
    }

    private func finish() {
        guard !result.done else { return }
        result.done = true
        current?.timer?.cancel()
        current = nil
        unlisten()
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: 70 tests passed (69 ported + the RNG parity test).

- [ ] **Step 6: Commit**

```bash
git add Sources/PacEngine/Apps/Traceroute.swift Tests/PacEngineTests
git commit -m "feat(swift): add traceroute and verify determinism"
```

---

### Task 11: Remove the TypeScript engine

**Files:**
- Delete: `src/`, `package.json`, `package-lock.json`, `tsconfig.json` (the `.gitignore` Node.js block stays: harmless, and `legacy/` may still be served with `npx`)

**Interfaces:**
- Consumes: green Swift suite from Task 10.

- [ ] **Step 1: Prove the Swift suite is green and complete**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: `Test run with 70 tests … passed`.

- [ ] **Step 2: Delete the TypeScript project**

```bash
git rm -r -q src package.json package-lock.json tsconfig.json
rm -rf node_modules
```

- [ ] **Step 3: Verify nothing else referenced it**

Run: `scripts/test.sh 2>&1 | tail -1 && git status --short`
Expected: suite still passes; status shows only the deletions.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: remove TypeScript engine, superseded by PacEngine"
```

---

## Done criteria for M1s

- `scripts/test.sh` reports 70 passing tests, including exact values (98 B, 0xB861, RTT 4 329 600 / 2 195 200 ns), RNG parity with the TS reference, and determinism.
- No TypeScript left in `src/`; the repo builds with `swift build` from Command Line Tools.
- Next: M2a plan in SwiftUI (`PacKit` + `PacTrack` targets), written against the real `PacEngine` API.
