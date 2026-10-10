/// OSPFv2 (RFC 2328, spec M8 §4): IP protocol 89; AllSPFRouters (224.0.0.5) and AllDRouters (224.0.0.6) with their MACs.
let IPPROTO_OSPF: UInt8 = 89
let OSPF_ALL_ROUTERS: UInt32 = 0xE000_0005
let OSPF_ALL_DROUTERS: UInt32 = 0xE000_0006
let OSPF_ALL_ROUTERS_MAC: Mac = "01:00:5e:00:00:05"
let OSPF_ALL_DROUTERS_MAC: Mac = "01:00:5e:00:00:06"
/// Seconds: an LSA this old leaves the database.
let OSPF_MAX_AGE = 3600
let OSPF_INITIAL_SEQ = Int32(bitPattern: 0x8000_0001)
/// Hello and dead intervals carried in every Hello (IOS defaults, not configurable).
let OSPF_HELLO_S = 10
let OSPF_DEAD_S = 40
/// Router-LSA link types (RFC 2328 A.4.2).
let LINK_P2P: UInt8 = 1
let LINK_TRANSIT: UInt8 = 2
let LINK_STUB: UInt8 = 3

/// An LSA's identity: type (1 router, 2 network), link state ID, advertising router.
struct LsaKey: Hashable, Comparable, Sendable {
    var type: UInt8
    var id: UInt32
    var adv: UInt32

    static func < (a: LsaKey, b: LsaKey) -> Bool { (a.type, a.id, a.adv) < (b.type, b.id, b.adv) }
}

/// The 20-byte LSA header; options are always 0x02 (E).
struct LsaHeader: Equatable, Sendable {
    /// Seconds.
    var age: Int
    var type: UInt8
    var id: UInt32
    var adv: UInt32
    var seq: Int32
    var checksum: UInt16
    var length: Int

    var key: LsaKey { LsaKey(type: type, id: id, adv: adv) }
}

/// One link of a router-LSA: point-to-point (id = neighbour's router ID, data = own address), transit (id = DR's address,
/// data = own address) or stub (id = network, data = mask).
struct RouterLink: Equatable, Sendable {
    var type: UInt8
    var id: UInt32
    var data: UInt32
    var metric: Int
}

enum LsaBody: Equatable, Sendable {
    case router([RouterLink])
    /// The network's mask and the routers attached to it, the DR first.
    case network(prefix: Int, routers: [UInt32])

    var size: Int {
        switch self {
        case .router(let links): 4 + 12 * links.count
        case .network(_, let routers): 4 + 4 * routers.count
        }
    }
}

struct Lsa: Equatable, Sendable {
    var header: LsaHeader
    var body: LsaBody
}

func serialize(_ h: LsaHeader) -> [UInt8] {
    var b = u16(UInt16(h.age))
    b += [0x02, h.type]
    b += u32(h.id)
    b += u32(h.adv)
    b += u32(UInt32(bitPattern: h.seq))
    b += u16(h.checksum)
    b += u16(UInt16(h.length))
    return b
}

func serialize(_ l: Lsa) -> [UInt8] {
    var b = serialize(l.header)
    switch l.body {
    case .router(let links):
        b += [0, 0]
        b += u16(UInt16(links.count))
        for k in links {
            b += u32(k.id)
            b += u32(k.data)
            b += [k.type, 0]
            b += u16(UInt16(k.metric))
        }
    case .network(let prefix, let routers):
        b += u32(prefixMask(prefix))
        for r in routers { b += u32(r) }
    }
    return b
}

/// ISO 8473 Fletcher checksum (RFC 2328 §12.1.7) for the two bytes at `offset`, so that the whole buffer sums to zero.
func fletcher(_ data: [UInt8], at offset: Int) -> UInt16 {
    var b = data
    b[offset] = 0
    b[offset + 1] = 0
    var c0 = 0
    var c1 = 0
    for byte in b {
        c0 = (c0 + Int(byte)) % 255
        c1 = (c1 + c0) % 255
    }
    var x = ((b.count - offset - 1) * c0 - c1) % 255
    if x <= 0 { x += 255 }
    var y = 510 - c0 - x
    if y > 255 { y -= 255 }
    return UInt16(x) << 8 | UInt16(y)
}

/// A new LSA with its length and its checksum, computed over everything but the age (the checksum sits 14 bytes in).
func makeLsa(age: Int = 0, type: UInt8, id: UInt32, adv: UInt32, seq: Int32, body: LsaBody) -> Lsa {
    var l = Lsa(header: LsaHeader(age: age, type: type, id: id, adv: adv, seq: seq, checksum: 0, length: 20 + body.size), body: body)
    l.header.checksum = fletcher(Array(serialize(l).dropFirst(2)), at: 14)
    return l
}

/// Hello: the network mask, priority, DR and BDR as the sender sees them (addresses), neighbours heard (router IDs).
struct OspfHello: Equatable, Sendable {
    var prefix: Int
    var priority: Int
    var dr: UInt32
    var bdr: UInt32
    var neighbors: [UInt32]
}

/// Database Description: the I, M and MS bits, the DD sequence number and LSA headers (MTU 1500, options E).
struct OspfDbd: Equatable, Sendable {
    var initial: Bool
    var more: Bool
    var master: Bool
    var seq: UInt32
    var headers: [LsaHeader]
}

enum OspfBody: Equatable, Sendable {
    case hello(OspfHello)
    case dbd(OspfDbd)
    case request([LsaKey])
    case update([Lsa])
    case ack([LsaHeader])

    var type: UInt8 {
        switch self {
        case .hello: 1
        case .dbd: 2
        case .request: 3
        case .update: 4
        case .ack: 5
        }
    }

    var size: Int {
        switch self {
        case .hello(let h): 20 + 4 * h.neighbors.count
        case .dbd(let d): 8 + 20 * d.headers.count
        case .request(let keys): 12 * keys.count
        case .update(let lsas): 4 + lsas.reduce(0) { $0 + $1.header.length }
        case .ack(let headers): 20 * headers.count
        }
    }
}

/// An OSPFv2 packet: 24-byte header (version 2, type, length, router ID, area 0.0.0.0, checksum, no authentication) and body.
struct OspfPacket: Equatable, Sendable {
    var routerId: UInt32
    var checksum: UInt16
    var body: OspfBody

    var size: Int { 24 + body.size }
}

func serialize(_ p: OspfPacket) -> [UInt8] {
    var b: [UInt8] = [2, p.body.type]
    b += u16(UInt16(p.size))
    b += u32(p.routerId)
    b += u32(0) // area 0.0.0.0
    b += u16(p.checksum)
    b += u16(0) // AuType: none
    b += [UInt8](repeating: 0, count: 8)
    switch p.body {
    case .hello(let h):
        b += u32(prefixMask(h.prefix))
        b += u16(UInt16(OSPF_HELLO_S))
        b += [0x02, UInt8(h.priority)]
        b += u32(UInt32(OSPF_DEAD_S))
        b += u32(h.dr)
        b += u32(h.bdr)
        for n in h.neighbors { b += u32(n) }
    case .dbd(let d):
        b += u16(1500)
        b += [0x02, (d.initial ? 4 : 0) | (d.more ? 2 : 0) | (d.master ? 1 : 0)]
        b += u32(d.seq)
        for h in d.headers { b += serialize(h) }
    case .request(let keys):
        for k in keys {
            b += u32(UInt32(k.type))
            b += u32(k.id)
            b += u32(k.adv)
        }
    case .update(let lsas):
        b += u32(UInt32(lsas.count))
        for l in lsas { b += serialize(l) }
    case .ack(let headers):
        for h in headers { b += serialize(h) }
    }
    return b
}

/// A packet with its checksum (RFC 2328 A.3.1: the IP checksum of the packet; the authentication field is zero here).
func makeOspf(routerId: UInt32, _ body: OspfBody) -> OspfPacket {
    var p = OspfPacket(routerId: routerId, checksum: 0, body: body)
    p.checksum = internetChecksum(serialize(p))
    return p
}
