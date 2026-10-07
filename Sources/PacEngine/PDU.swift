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
