import Foundation

/// IPv6 on the wire (spec M9 §2–§3): 128-bit addresses, the 40-byte header, ICMPv6 and NDP messages.

let ETHERTYPE_IPV6: UInt16 = 0x86DD
let IPPROTO_ICMPV6: UInt8 = 58
/// ICMPv6 (RFC 4443): the types and codes Pac-Track sends.
let ICMP6_DEST_UNREACH: UInt8 = 1
let ICMP6_PACKET_TOO_BIG: UInt8 = 2
let ICMP6_TIME_EXCEEDED: UInt8 = 3
let ICMP6_ECHO_REQUEST: UInt8 = 128
let ICMP6_ECHO_REPLY: UInt8 = 129
let UNREACH6_NO_ROUTE: UInt8 = 0
let UNREACH6_ADDRESS: UInt8 = 3
let UNREACH6_PORT: UInt8 = 4
/// NDP message types (RFC 4861 §4).
let ND_RS: UInt8 = 133
let ND_RA: UInt8 = 134
let ND_NS: UInt8 = 135
let ND_NA: UInt8 = 136
/// An ICMPv6 error carries as much of the packet it is about as fits in the minimum IPv6 MTU (RFC 4443 §2.4 c).
let IPV6_MIN_MTU = 1280
/// IOS Router Advertisement defaults (spec M9 §5): router lifetime, prefix valid and preferred lifetimes, link MTU.
let RA_LIFETIME_S: UInt16 = 1800
let ND_VALID_LIFETIME: UInt32 = 2_592_000
let ND_PREFERRED_LIFETIME: UInt32 = 604_800
let RA_MTU: UInt32 = 1500

let LINK_LOCAL_PREFIX = UInt128(0xFE80) << 112
/// ff02::1 (all nodes) and ff02::2 (all routers).
let ALL_NODES = UInt128(0xFF02) << 112 | 1
let ALL_ROUTERS = UInt128(0xFF02) << 112 | 2

struct Cidr6: Equatable, Sendable {
    var addr: UInt128
    var prefix: Int
}

/// RFC 4291 §2.2 text: groups of 1–4 hex digits in any case, at most one "::". No dotted IPv4 tail and no zone (spec M9 §2).
func parseIp6(_ s: String) throws -> UInt128 {
    let bad = EngineError("Invalid IPv6 address: \"\(s)\"")
    let halves = s.components(separatedBy: "::")
    guard halves.count <= 2 else { throw bad }
    func groups(_ part: String) throws -> [UInt128] {
        guard !part.isEmpty else { return [] }
        return try part.split(separator: ":", omittingEmptySubsequences: false).map { g in
            guard (1...4).contains(g.count), g.allSatisfy({ $0.isASCII && $0.isHexDigit }), let v = UInt16(g, radix: 16) else { throw bad }
            return UInt128(v)
        }
    }
    let head = try groups(halves[0])
    let tail = try halves.count == 2 ? groups(halves[1]) : []
    let count = head.count + tail.count
    guard halves.count == 2 ? count <= 7 : count == 8 else { throw bad }
    return (head + Array(repeating: 0, count: 8 - count) + tail).reduce(0) { $0 << 16 | $1 }
}

/// RFC 5952: lowercase, no leading zeros, the longest run of two or more zero groups (the first on a tie) written "::".
func formatIp6(_ a: UInt128) -> String {
    let g = (0..<8).map { Int(truncatingIfNeeded: a >> (112 - 16 * $0)) & 0xFFFF }
    var run = (start: 0, length: 0)
    var i = 0
    while i < 8 {
        var j = i
        while j < 8 && g[j] == 0 { j += 1 }
        if j - i > run.length { run = (i, j - i) }
        i = j + 1
    }
    let text = { (part: ArraySlice<Int>) in part.map { String($0, radix: 16) }.joined(separator: ":") }
    guard run.length >= 2 else { return text(g[...]) }
    return text(g[..<run.start]) + "::" + text(g[(run.start + run.length)...])
}

/// "2001:db8::1/64"; the prefix is 0–128.
func parseCidr6(_ s: String) throws -> Cidr6 {
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, (1...3).contains(parts[1].count), parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
          let prefix = Int(parts[1]), prefix <= 128 else { throw EngineError("Invalid IPv6 prefix: \"\(s)\"") }
    return Cidr6(addr: try parseIp6(String(parts[0])), prefix: prefix)
}

func prefixMask6(_ prefix: Int) -> UInt128 {
    prefix == 0 ? 0 : UInt128.max << (128 - prefix)
}

func networkOf6(_ a: UInt128, _ prefix: Int) -> UInt128 {
    a & prefixMask6(prefix)
}

func inSubnet6(_ a: UInt128, _ network: UInt128, _ prefix: Int) -> Bool {
    networkOf6(a, prefix) == networkOf6(network, prefix)
}

/// fe80::/10.
func isLinkLocal6(_ a: UInt128) -> Bool {
    a >> 118 == 0x3FA
}

/// ff00::/8.
func isMulticast6(_ a: UInt128) -> Bool {
    a >> 120 == 0xFF
}

func macBytes(_ mac: Mac) -> [UInt8] {
    mac.split(separator: ":").map { UInt8($0, radix: 16) ?? 0 }
}

/// Modified EUI-64 interface identifier (RFC 4291 app. A): the MAC with the U/L bit flipped and ff:fe in the middle.
func eui64(_ mac: Mac) -> UInt128 {
    var b = macBytes(mac)
    b[0] ^= 0x02
    return (Array(b[0..<3]) + [0xFF, 0xFE] + Array(b[3..<6])).reduce(0) { $0 << 8 | UInt128($1) }
}

/// fe80::/64 + EUI-64 (spec M9 §2).
func linkLocal(_ mac: Mac) -> UInt128 {
    LINK_LOCAL_PREFIX | eui64(mac)
}

/// ff02::1:ff00:0/104 + the address's low 24 bits (RFC 4291 §2.7.1).
func solicitedNode(_ a: UInt128) -> UInt128 {
    UInt128(0xFF02) << 112 | UInt128(0x1_FF00_0000) | a & 0xFF_FFFF
}

/// 33:33 + the group's low 32 bits (RFC 2464 §7).
func multicastMac6(_ group: UInt128) -> Mac {
    "33:33:" + (0..<4).map { hex2(Int(truncatingIfNeeded: group >> (24 - 8 * $0)) & 0xFF) }.joined(separator: ":")
}

/// The 16 bytes of an address, network order.
func bytes16(_ a: UInt128) -> [UInt8] {
    (0..<16).map { UInt8(truncatingIfNeeded: a >> (120 - 8 * $0)) }
}

/// A Prefix Information option (RFC 4861 §4.6.2) as IOS sends it: on-link and autonomous, with IOS's lifetimes.
struct PrefixInfo: Equatable, Sendable {
    var prefix: UInt128
    var length: Int
    var valid = ND_VALID_LIFETIME
    var preferred = ND_PREFERRED_LIFETIME
}

/// A Router Advertisement with IOS defaults (spec M9 §5): flags M and O, reachable time and retrans timer are 0.
struct RouterAdvert: Equatable, Sendable {
    var hopLimit: UInt8 = 64
    var lifetime = RA_LIFETIME_S
    var slla: Mac
    var mtu = RA_MTU
    var prefixes: [PrefixInfo]
}

/// NDP bodies (RFC 4861 §4) with the link-layer address options Pac-Track uses; an NA always carries the target's.
enum NdpBody: Equatable, Sendable {
    case rs(slla: Mac?)
    case ra(RouterAdvert)
    case ns(target: UInt128, slla: Mac?)
    case na(target: UInt128, router: Bool, solicited: Bool, override: Bool, tlla: Mac)
}

/// An NDP message: an ICMPv6 message with its own body.
struct NdpMessage: Equatable, Sendable {
    var body: NdpBody
    var checksum: UInt16 = 0

    var type: UInt8 {
        switch body {
        case .rs: ND_RS
        case .ra: ND_RA
        case .ns: ND_NS
        case .na: ND_NA
        }
    }

    /// Header and fields, plus 8 B per link-layer address option, 8 B of MTU and 32 B per prefix.
    var size: Int {
        switch body {
        case .rs(let slla): 8 + (slla == nil ? 0 : 8)
        case .ra(let ra): 32 + 32 * ra.prefixes.count
        case .ns(_, let slla): 24 + (slla == nil ? 0 : 8)
        case .na: 32
        }
    }
}

/// What an IPv6 packet carries: ICMPv6 echo and errors (ICMPv4's header layout, so `IcmpMessage`), NDP, UDP.
enum Ipv6Payload: Equatable, Sendable {
    case icmp(IcmpMessage)
    case ndp(NdpMessage)
    case udp(UdpDatagram)

    var size: Int {
        switch self {
        case .icmp(let m): m.size
        case .ndp(let n): n.size
        case .udp(let u): u.size
        }
    }

    var nextHeader: UInt8 {
        switch self {
        case .icmp, .ndp: IPPROTO_ICMPV6
        case .udp: IPPROTO_UDP
        }
    }
}

/// The 40-byte IPv6 header (RFC 8200) with traffic class and flow label 0 and no extension headers (spec M9 §3).
struct Ipv6Packet: Equatable, Sendable {
    var hopLimit: UInt8
    var src: UInt128
    var dst: UInt128
    var payload: Ipv6Payload

    var size: Int { 40 + payload.size }
}

func serializeHeader(_ p: Ipv6Packet) -> [UInt8] {
    var b: [UInt8] = [0x60, 0, 0, 0]
    b += u16(UInt16(truncatingIfNeeded: p.payload.size))
    b += [p.payload.nextHeader, p.hopLimit]
    return b + bytes16(p.src) + bytes16(p.dst)
}

private func llaOption(_ type: UInt8, _ mac: Mac) -> [UInt8] {
    [type, 1] + macBytes(mac)
}

func serialize(_ m: NdpMessage) -> [UInt8] {
    var b: [UInt8] = [m.type, 0]
    b += u16(m.checksum)
    switch m.body {
    case .rs(let slla):
        b += u32(0)
        if let slla { b += llaOption(1, slla) }
    case .ra(let ra):
        b += [ra.hopLimit, 0]
        b += u16(ra.lifetime)
        b += u32(0) + u32(0) // reachable time, retrans timer
        b += llaOption(1, ra.slla)
        b += [5, 1, 0, 0] + u32(ra.mtu)
        for p in ra.prefixes {
            b += [3, 4, UInt8(truncatingIfNeeded: p.length), 0xC0] // L and A
            b += u32(p.valid) + u32(p.preferred) + u32(0) + bytes16(p.prefix)
        }
    case .ns(let target, let slla):
        b += u32(0) + bytes16(target)
        if let slla { b += llaOption(1, slla) }
    case .na(let target, let router, let solicited, let override, let tlla):
        let flags: UInt8 = (router ? 0x80 : 0) | (solicited ? 0x40 : 0) | (override ? 0x20 : 0)
        b += [flags, 0, 0, 0] + bytes16(target) + llaOption(2, tlla)
    }
    return b
}

func serializePayload(_ p: Ipv6Packet) -> [UInt8] {
    switch p.payload {
    case .icmp(let m): serialize(m)
    case .ndp(let n): serialize(n)
    case .udp(let u): serialize(u)
    }
}

/// What ICMPv6 and UDP checksums cover besides the message (RFC 8200 §8.1).
func pseudoHeader6(_ src: UInt128, _ dst: UInt128, _ length: Int, _ nextHeader: UInt8) -> [UInt8] {
    bytes16(src) + bytes16(dst) + u32(UInt32(truncatingIfNeeded: length)) + [0, 0, 0, nextHeader]
}

/// A packet with its payload's checksum filled in: mandatory for ICMPv6 and for UDP over IPv6, where a sum of 0 is sent as ffff.
func makeIpv6(src: UInt128, dst: UInt128, hopLimit: UInt8, payload: Ipv6Payload) -> Ipv6Packet {
    let pseudo = pseudoHeader6(src, dst, payload.size, payload.nextHeader)
    let sealed: Ipv6Payload
    switch payload {
    case .icmp(var m):
        m.checksum = 0
        m.checksum = internetChecksum(pseudo + serialize(m))
        sealed = .icmp(m)
    case .ndp(var n):
        n.checksum = 0
        n.checksum = internetChecksum(pseudo + serialize(n))
        sealed = .ndp(n)
    case .udp(var u):
        u.checksum = 0
        let sum = internetChecksum(pseudo + serialize(u))
        u.checksum = sum == 0 ? 0xFFFF : sum
        sealed = .udp(u)
    }
    return Ipv6Packet(hopLimit: hopLimit, src: src, dst: dst, payload: sealed)
}
