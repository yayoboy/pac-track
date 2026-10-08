let ETHERTYPE_IPV4: UInt16 = 0x0800
let ETHERTYPE_ARP: UInt16 = 0x0806
let IPPROTO_ICMP: UInt8 = 1
let IPPROTO_UDP: UInt8 = 17
let IPPROTO_TCP: UInt8 = 6

let ICMP_ECHO_REPLY: UInt8 = 0
let ICMP_DEST_UNREACH: UInt8 = 3
let ICMP_ECHO_REQUEST: UInt8 = 8
let ICMP_TIME_EXCEEDED: UInt8 = 11
let UNREACH_NET: UInt8 = 0
let UNREACH_HOST: UInt8 = 1
let UNREACH_PORT: UInt8 = 3
let UNREACH_FRAG_NEEDED: UInt8 = 4

let PORT_DHCP_SERVER: UInt16 = 67
let PORT_DHCP_CLIENT: UInt16 = 68
let PORT_DNS: UInt16 = 53
/// Discard service (RFC 863): the traffic generator's receiver, TCP and UDP.
let PORT_DISCARD: UInt16 = 9
let DNS_NXDOMAIN: UInt8 = 3
/// iperf3's default UDP payload: with UDP, IPv4 and Ethernet headers the frame stays within a 1500-byte MTU.
let TRAFFIC_DATAGRAM = 1470

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

/// DHCP message type, option 53 (RFC 2132 §9.6).
enum DhcpType: UInt8, Sendable {
    case discover = 1, offer, request, decline, ack, nak, release

    var name: String {
        switch self {
        case .discover: "Discover"
        case .offer: "Offer"
        case .request: "Request"
        case .decline: "Decline"
        case .ack: "ACK"
        case .nak: "NAK"
        case .release: "Release"
        }
    }
}

/// BOOTP message with the DHCP options Pac-Track uses (53/50/51/54/1/3/6); absent options are not sent.
/// giaddr is always 0 (no relay agents) and `secs` 0.
struct DhcpMessage: Equatable, Sendable {
    /// 1 BOOTREQUEST, 2 BOOTREPLY.
    var op: UInt8
    var xid: UInt32
    var broadcast: Bool
    var ciaddr: UInt32 = 0
    var yiaddr: UInt32 = 0
    var siaddr: UInt32 = 0
    var chaddr: Mac
    var type: DhcpType
    var requestedIp: UInt32? = nil
    var leaseS: UInt32? = nil
    var serverId: UInt32? = nil
    var subnetMask: UInt32? = nil
    var router: UInt32? = nil
    var dns: UInt32? = nil

    /// Options after the magic cookie: 53 (3 B), each 4-byte option 6 B, end (1 B).
    var optionsSize: Int {
        3 + 6 * [requestedIp, leaseS, serverId, subnetMask, router, dns].filter { $0 != nil }.count + 1
    }

    /// Fixed BOOTP fields 236 B + magic cookie 4 B + options, padded to the 300-byte BOOTP minimum (RFC 1542) as real clients and servers do.
    var size: Int { max(300, 240 + optionsSize) }
}

struct DnsAnswer: Equatable, Sendable {
    var ttl: UInt32
    var addr: UInt32
}

/// One-question DNS message for an A record (class IN); answers repeat the question name.
struct DnsMessage: Equatable, Sendable {
    var id: UInt16
    var response: Bool
    var authoritative = false
    var recursionDesired = true
    /// 0 NOERROR, 3 NXDOMAIN.
    var rcode: UInt8 = 0
    var name: String
    var answers: [DnsAnswer] = []

    var flags: UInt16 {
        (response ? 0x8000 : 0) | (authoritative ? 0x0400 : 0) | (recursionDesired ? 0x0100 : 0) | UInt16(rcode)
    }

    /// Header 12 B + question (labels + type + class) + answers of 16 B (name as a 2-byte pointer, type, class, TTL, length, address).
    var size: Int {
        12 + name.split(separator: ".").reduce(1) { $0 + 1 + $1.utf8.count } + 4 + 16 * answers.count
    }
}

/// A traffic generator datagram: like iperf3's payload it carries a sequence number and the send time (plus the flow id the sink reports to).
struct TrafficData: Equatable, Sendable {
    var flow: Int
    var seq: Int
    var sentAt: Int
}

enum UdpPayload: Equatable, Sendable {
    case raw([UInt8])
    case dhcp(DhcpMessage)
    case dns(DnsMessage)
    case traffic(TrafficData)

    var size: Int {
        switch self {
        case .raw(let bytes): bytes.count
        case .dhcp(let m): m.size
        case .dns(let m): m.size
        case .traffic: TRAFFIC_DATAGRAM
        }
    }
}

struct UdpDatagram: Equatable, Sendable {
    var srcPort: UInt16
    var dstPort: UInt16
    var checksum: UInt16
    var payload: UdpPayload

    var size: Int { 8 + payload.size }
}

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

enum L4: Equatable, Sendable {
    case icmp(IcmpMessage)
    case udp(UdpDatagram)
    case tcp(TcpSegment)

    var size: Int {
        switch self {
        case .icmp(let m): m.size
        case .udp(let u): u.size
        case .tcp(let t): t.size
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
    // ponytail: DHCP and DNS bodies stay typed, not byte-encoded; only the 8-byte header is ever quoted (ICMP errors)
    if case .raw(let data) = u.payload { b += data }
    return b
}

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
    case .tcp(let t): serialize(t)
    }
}

func makeIcmp(type: UInt8, code: UInt8, id: UInt16, seq: UInt16, data: [UInt8]) -> IcmpMessage {
    var m = IcmpMessage(type: type, code: code, checksum: 0, id: id, seq: seq, data: data)
    m.checksum = internetChecksum(serialize(m))
    return m
}

func makeUdp(srcPort: UInt16, dstPort: UInt16, data: [UInt8]) -> UdpDatagram {
    makeUdp(srcPort: srcPort, dstPort: dstPort, payload: .raw(data))
}

func makeUdp(srcPort: UInt16, dstPort: UInt16, payload: UdpPayload) -> UdpDatagram {
    // ponytail: UDP checksum left 0 (optional over IPv4, RFC 768); add pseudo-header checksum if a lab needs it
    UdpDatagram(srcPort: srcPort, dstPort: dstPort, checksum: 0, payload: payload)
}

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
    case .tcp: IPPROTO_TCP
    }
    return withChecksum(Ipv4Packet(tos: tos, id: id, dontFragment: dontFragment, ttl: ttl, proto: proto,
                                   checksum: 0, src: src, dst: dst, payload: payload))
}

func withTtl(_ p: Ipv4Packet, _ ttl: UInt8) -> Ipv4Packet {
    var q = p
    q.ttl = ttl
    return withChecksum(q)
}

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
/// (RFC 5508 §4), or with `destination` a new destination address and port, as NAT sends an inside host's error out (TCP and UDP
/// quotes only): the quoted IPv4 checksum is recomputed and a quoted echo's adjusted (RFC 1624); a quoted UDP checksum is 0
/// and TCP's lies beyond the 8 quoted bytes. `m` must quote a flow (`quotedEndpoints(m) != nil`).
func withQuotedEndpoint(_ m: IcmpMessage, _ addr: UInt32, _ port: UInt16, destination: Bool = false) -> IcmpMessage {
    var q = m.data
    let echo = q[9] == IPPROTO_ICMP
    let at = destination ? 22 : echo ? 24 : 20
    if echo { q.replaceSubrange(22..<24, with: u16(adjusted(word16(q, 22), word16(q, at), port))) }
    q.replaceSubrange(at..<at + 2, with: u16(port))
    let a = destination ? 16 : 12
    q.replaceSubrange(a..<a + 4, with: u32(addr))
    q.replaceSubrange(10..<12, with: [0, 0])
    q.replaceSubrange(10..<12, with: u16(internetChecksum(Array(q[0..<20]))))
    return makeIcmp(type: m.type, code: m.code, id: m.id, seq: m.seq, data: q)
}
