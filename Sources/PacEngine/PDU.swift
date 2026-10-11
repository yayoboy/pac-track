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
/// DNS record types (RFC 1035 §3.2.2, RFC 3596 §2.1).
let DNS_TYPE_A: UInt16 = 1
let DNS_TYPE_AAAA: UInt16 = 28
/// iperf3's default UDP payload: with UDP, IPv4 and Ethernet headers the frame stays within a 1500-byte MTU.
let TRAFFIC_DATAGRAM = 1470
/// The same over IPv6, whose header is 20 B longer: the packet stays at 1498 B (spec M9 §10).
let TRAFFIC_DATAGRAM6 = 1450
/// Cisco Shared Spanning Tree Protocol group address: PVST+ BPDUs go here (spec M7 §4).
let SSTP_MAC: Mac = "01:00:0c:cc:cc:cd"
/// 802.1D timers, Cisco defaults (not configurable): hello, max age, forward delay, and how long the root flags a topology change.
let STP_HELLO_NS = 2 * S
let STP_MAX_AGE_NS = 20 * S
let STP_FORWARD_DELAY_NS = 15 * S
let STP_TC_NS = STP_MAX_AGE_NS + STP_FORWARD_DELAY_NS
/// RIPv2 (RFC 2453, spec M8 §3): its UDP port, the RIP-2 routers group (224.0.0.9) and that group's MAC.
let PORT_RIP: UInt16 = 520
let RIP_GROUP: UInt32 = 0xE000_0009
let RIP_MAC: Mac = "01:00:5e:00:00:09"
let RIP_REQUEST: UInt8 = 1
let RIP_RESPONSE: UInt8 = 2
/// Hop count meaning "unreachable".
let RIP_INFINITY = 16
/// Route entries per message (RFC 2453 §4: at most 512 bytes of RIP).
let RIP_MAX_ENTRIES = 25
/// 802.11g ERP-OFDM timing with short slots (IEEE 802.11-2016 §17.4.3, §18; spec M11 §4), in µs.
let DOT11_SLOT_US = 9
let DOT11_SIFS_US = 10
/// DIFS = SIFS + 2 slots (§10.3.2.3.7).
let DOT11_DIFS_US = DOT11_SIFS_US + 2 * DOT11_SLOT_US
/// Always 7 slots, half of CWmin = 15: a fixed value instead of the draw (spec M11 §4).
let DOT11_BACKOFF_US = 7 * DOT11_SLOT_US
/// ERP-OFDM's signal extension after every PPDU (§18, aSignalExtension).
let DOT11_SIGNAL_EXTENSION_US = 6
/// Mb/s: unicast data; management and group frames (the lowest basic rate); ACKs after data (the highest basic rate not above 54).
/// An ACK goes at the highest basic rate not above the frame's (§10.7.6.5.2): 24 after 54 Mb/s, 6 after 6.
let DOT11_DATA_RATE = 54
let DOT11_BASIC_RATE = 6
let DOT11_ACK_RATE = 24
/// An ACK: frame control, duration, receiver address, FCS.
let DOT11_ACK_BYTES = 14
/// SIFS + the ACK: the Duration of a unicast data frame (§9.2.5.2), and how long the medium stays busy after it.
let DOT11_ACK_US = DOT11_SIFS_US + dot11TxUs(bytes: DOT11_ACK_BYTES, rateMbps: DOT11_ACK_RATE)
/// Frames a radio holds while the medium is busy, like a cable's default queue (spec M11 §4).
let DOT11_QUEUE_LIMIT = 1000
/// Reason 3: deauthenticated because the sending station is leaving the BSS (§9.4.1.7).
let DOT11_REASON_LEAVING = 3
/// Capability information: ESS (bit 0) and short slot time (bit 10) (§9.4.1.4).
let DOT11_CAPABILITY = 0x0401
/// The beacon interval a Probe Response advertises, in TU of 1024 µs.
let DOT11_BEACON_TU = 100
/// The listen interval of an Association Request, in beacon intervals.
let DOT11_LISTEN_INTERVAL = 10
/// Supported rates in Mb/s, and the basic ones (spec M11 §3).
let DOT11_RATES = [6, 9, 12, 18, 24, 36, 48, 54]
let DOT11_BASIC_RATES: Set = [6, 12, 24]

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

func dnsTypeName(_ type: UInt16) -> String {
    type == DNS_TYPE_AAAA ? "AAAA" : "A"
}

struct DnsAnswer: Equatable, Sendable {
    var ttl: UInt32
    /// The record's data: an A's 32 bits or an AAAA's 128, as the message's `type` says.
    var addr: UInt128
}

/// One-question DNS message for an A or AAAA record (class IN); answers repeat the question name.
struct DnsMessage: Equatable, Sendable {
    var id: UInt16
    var response: Bool
    var authoritative = false
    var recursionDesired = true
    /// 0 NOERROR, 3 NXDOMAIN.
    var rcode: UInt8 = 0
    var name: String
    var answers: [DnsAnswer] = []
    var type = DNS_TYPE_A

    var flags: UInt16 {
        (response ? 0x8000 : 0) | (authoritative ? 0x0400 : 0) | (recursionDesired ? 0x0100 : 0) | UInt16(rcode)
    }

    /// Header 12 B + question (labels + type + class) + answers (name as a 2-byte pointer, type, class, TTL, length, then 4 B of
    /// address for an A, 16 for an AAAA: 16 or 28 B).
    var size: Int {
        12 + name.split(separator: ".").reduce(1) { $0 + 1 + $1.utf8.count } + 4 + (type == DNS_TYPE_AAAA ? 28 : 16) * answers.count
    }

    /// An answer's address, read as the question's type.
    func address(_ a: DnsAnswer) -> IpAddr {
        type == DNS_TYPE_AAAA ? .v6(a.addr) : .v4(UInt32(truncatingIfNeeded: a.addr))
    }
}

/// A traffic generator datagram: like iperf3's payload it carries a sequence number and the send time (plus the flow id the sink reports to).
struct TrafficData: Equatable, Sendable {
    var flow: Int
    var seq: Int
    var sentAt: Int
    /// The payload's size: smaller over IPv6.
    var bytes = TRAFFIC_DATAGRAM
}

/// One RIPv2 route entry (20 B: AFI, route tag 0, address, mask, next hop 0.0.0.0, metric). A whole-table request is a single
/// entry with AFI 0 and metric 16.
struct RipEntry: Equatable, Sendable {
    var afi: UInt16 = 2
    var network: UInt32
    var prefix: Int
    var metric: Int
}

/// A RIPv2 message: 4-byte header (command, version 2, zero) and its entries.
struct RipMessage: Equatable, Sendable {
    var command: UInt8
    var entries: [RipEntry]

    var size: Int { 4 + 20 * entries.count }
}

enum UdpPayload: Equatable, Sendable {
    case raw([UInt8])
    case dhcp(DhcpMessage)
    case dns(DnsMessage)
    case traffic(TrafficData)
    case rip(RipMessage)

    var size: Int {
        switch self {
        case .raw(let bytes): bytes.count
        case .dhcp(let m): m.size
        case .dns(let m): m.size
        case .traffic(let d): d.bytes
        case .rip(let m): m.size
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
    case ospf(OspfPacket)

    var size: Int {
        switch self {
        case .icmp(let m): m.size
        case .udp(let u): u.size
        case .tcp(let t): t.size
        case .ospf(let o): o.size
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

/// 802.1D bridge identifier with Cisco's extended system ID: priority (a multiple of 4096) plus VLAN, then the switch MAC.
struct BridgeId: Comparable, Sendable {
    var priority: Int
    var vlan: Int
    var mac: Mac

    static func < (a: BridgeId, b: BridgeId) -> Bool {
        (a.priority + a.vlan, a.mac) < (b.priority + b.vlan, b.mac)
    }

    /// Wireshark's notation: priority/VLAN/MAC.
    var text: String { "\(priority)/\(vlan)/\(mac)" }
}

/// An 802.1D configuration BPDU as PVST+ sends it: the sender's view of the tree (max age, hello and forward delay are the STP_* defaults).
struct StpConfig: Equatable, Sendable {
    var root: BridgeId
    var cost: Int
    var bridge: BridgeId
    /// Port ID: priority 128 in the high byte, port number in the low byte (0x8001 is 128.1).
    var port: Int
    /// Seconds since the root sent it: one more per bridge on the way.
    var messageAge: Int
    var tc = false
    var tca = false
}

enum Bpdu: Equatable, Sendable {
    case config(StpConfig)
    /// Topology change notification, sent toward the root.
    case tcn

    /// LLC/SNAP (8 B) + BPDU: a configuration (35 B) with Cisco's PVID TLV (7 B), or a TCN (4 B). It is also the 802.3 length field.
    var size: Int {
        switch self {
        case .config: 50
        case .tcn: 12
        }
    }
}

/// The 802.11 MAC header of a frame on the air (§9.2.3, spec M11 §3): set by the radio that transmits it, cleared by the access point
/// that bridges it to Ethernet. The frame keeps its Ethernet source and destination; address 1–3 follow from them and the direction.
struct Dot11Header: Equatable, Sendable {
    var toDS = false
    var fromDS = false
    /// The access point's radio MAC; broadcast (the wildcard BSSID) in a Probe Request.
    var bssid: Mac
    /// 12-bit sequence number of the transmitter (§9.2.4.4); fragment 0.
    var seq = 0
}

/// The management frames Pac-Track sends (§9.3.3, spec M11 §3), with the fields that vary.
enum Dot11Mgmt: Equatable, Sendable {
    case probeRequest(ssid: String)
    /// `timestamp`: the access point's clock in µs.
    case probeResponse(ssid: String, channel: Int, timestamp: Int)
    /// Open System (algorithm 0): transaction 1 from the station, 2 with the status from the access point.
    case authentication(seq: Int, status: Int)
    case associationRequest(ssid: String)
    case associationResponse(status: Int, aid: Int)
    case deauthentication(reason: Int)

    /// Subtype (Table 9-1).
    var subtype: Int {
        switch self {
        case .associationRequest: 0
        case .associationResponse: 1
        case .probeRequest: 4
        case .probeResponse: 5
        case .authentication: 11
        case .deauthentication: 12
        }
    }

    var name: String {
        switch self {
        case .probeRequest: "Probe Request"
        case .probeResponse: "Probe Response"
        case .authentication: "Authentication"
        case .associationRequest: "Association Request"
        case .associationResponse: "Association Response"
        case .deauthentication: "Deauthentication"
        }
    }

    /// Body: fixed fields, then the SSID (2 + length), Supported Rates (2 + 8) and DS Parameter Set (2 + 1) elements (§9.3.3.6–13).
    var size: Int {
        switch self {
        case .probeRequest(let ssid): 2 + ssid.utf8.count + 10
        case .probeResponse(let ssid, _, _): 8 + 2 + 2 + 2 + ssid.utf8.count + 10 + 3
        case .authentication: 6
        case .associationRequest(let ssid): 2 + 2 + 2 + ssid.utf8.count + 10
        case .associationResponse: 2 + 2 + 2 + 10
        case .deauthentication: 2
        }
    }
}

enum L3: Equatable, Sendable {
    case arp(ArpPacket)
    case ipv4(Ipv4Packet)
    /// IPv6 (spec M9), EtherType 0x86DD.
    case ipv6(Ipv6Packet)
    /// PVST+ BPDU, in an IEEE 802.3 frame with LLC/SNAP (`EthernetFrame.etherType` holds the 802.3 length).
    case bpdu(Bpdu)
    /// An 802.11 management frame (spec M11 §3): only on the air, never bridged.
    case mgmt(Dot11Mgmt)
}

struct EthernetFrame: Equatable, Sendable {
    var id: Int
    var src: Mac
    var dst: Mac
    var etherType: UInt16
    var payload: L3
    /// 802.1Q tag (TPID 0x8100, PCP and DEI 0): the VLAN ID; nil while the frame travels untagged.
    var vlan: Int? = nil
    /// The 802.11 header while the frame is on the air (spec M11 §3); nil on a cable.
    var air: Dot11Header? = nil

    /// Size as shown by Wireshark: Ethernet header (+ 4 B with a tag) + payload, no FCS; on the air the 802.11 header instead
    /// (spec M11 §3).
    var size: Int {
        let body = switch payload {
        case .arp: 28
        case .ipv4(let p): p.size
        case .ipv6(let p): p.size
        case .bpdu(let b): b.size
        case .mgmt(let m): m.size
        }
        // On the air: the 802.11 header, then LLC/SNAP before a packet (RFC 1042); a management body follows the header.
        if air != nil {
            if case .mgmt = payload { return 24 + body }
            return 24 + 8 + body
        }
        return (vlan == nil ? 14 : 18) + body
    }

    /// Address 1, the receiver (spec M11 §3): the BSSID of a data frame to the access point, else the destination.
    var receiver: Mac {
        if let air, air.toDS { return air.bssid }
        return dst
    }

    /// Bytes occupying the wire: frame + FCS padded to 64, plus preamble/SFD (8) and inter-frame gap (12). Frames are padded
    /// untagged and bridges tag them as they are, so a tag adds 4 bytes even to a minimum frame (64 → 68).
    var wireBytes: Int {
        let tag = vlan == nil ? 0 : 4
        return max(size - tag + 4, 64) + tag + 20
    }
}

/// µs on the air of a PPDU carrying `bytes` of MAC frame with its FCS (§17.4.3 and §18): preamble and SIGNAL (20 µs), 4 µs symbols of
/// 4 × rate data bits for the 16 SERVICE bits, the frame and the 6 tail bits, then the ERP signal extension.
func dot11TxUs(bytes: Int, rateMbps: Int) -> Int {
    let bits = 16 + 8 * bytes + 6
    let perSymbol = 4 * rateMbps
    return 20 + 4 * ((bits + perSymbol - 1) / perSymbol) + DOT11_SIGNAL_EXTENSION_US
}

/// The medium's time for one frame (spec M11 §4): DIFS, backoff and the PPDU until it is received, then SIFS + ACK for a unicast
/// one (its Duration field). Unicast data goes at 54 Mb/s, management and group frames at 6; the ACK at 24 or 6.
func dot11Airtime(_ f: EthernetFrame) -> (frame: Int, ack: Int) {
    let group = isGroupMac(f.receiver)
    let mgmt = if case .mgmt = f.payload { true } else { false }
    let rate = mgmt || group ? DOT11_BASIC_RATE : DOT11_DATA_RATE
    let ack = DOT11_SIFS_US + dot11TxUs(bytes: DOT11_ACK_BYTES, rateMbps: min(rate, DOT11_ACK_RATE))
    return (DOT11_DIFS_US + DOT11_BACKOFF_US + dot11TxUs(bytes: f.size + 4, rateMbps: rate), group ? 0 : ack)
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

func u16(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 0xFF)] }
func u32(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }

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
    case .ospf(let o): serialize(o)
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
    case .ospf: IPPROTO_OSPF
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
/// `id → 0`, its reply `0 → id`), so a reply is always the mirror image of its request. IPv4 for NAT and the firewall, IPv6 for the
/// firewall (spec M9 §10).
struct Endpoints<Addr: Equatable>: Equatable {
    var proto: UInt8
    var src: Addr
    var srcPort: UInt16
    var dst: Addr
    var dstPort: UInt16

    var reversed: Endpoints { Endpoints(proto: proto, src: dst, srcPort: dstPort, dst: src, dstPort: srcPort) }
}

/// nil for ICMP other than echo: an error belongs to the flow it quotes (`quotedEndpoints`).
func endpoints(_ p: Ipv4Packet) -> Endpoints<UInt32>? {
    switch p.payload {
    case .tcp(let t): return Endpoints(proto: IPPROTO_TCP, src: p.src, srcPort: t.srcPort, dst: p.dst, dstPort: t.dstPort)
    case .udp(let u): return Endpoints(proto: IPPROTO_UDP, src: p.src, srcPort: u.srcPort, dst: p.dst, dstPort: u.dstPort)
    case .icmp(let m) where m.type == ICMP_ECHO_REQUEST:
        return Endpoints(proto: IPPROTO_ICMP, src: p.src, srcPort: m.id, dst: p.dst, dstPort: 0)
    case .icmp(let m) where m.type == ICMP_ECHO_REPLY:
        return Endpoints(proto: IPPROTO_ICMP, src: p.src, srcPort: 0, dst: p.dst, dstPort: m.id)
    case .icmp: return nil
    case .ospf: return nil // no ports: NAT and stateful filtering leave it alone
    }
}

/// The flow an ICMP error is about, read from the IPv4 header and first 8 bytes it quotes (RFC 792), as its sender sent it.
func quotedEndpoints(_ m: IcmpMessage) -> Endpoints<UInt32>? {
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
    case .ospf:
        break // NAT never rewrites routing protocol packets
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
