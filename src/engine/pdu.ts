import type { Mac } from './addr'

export const ETHERTYPE_IPV4 = 0x0800
export const ETHERTYPE_ARP = 0x0806
export const IPPROTO_ICMP = 1
export const IPPROTO_UDP = 17

export const ICMP_ECHO_REPLY = 0
export const ICMP_DEST_UNREACH = 3
export const ICMP_ECHO_REQUEST = 8
export const ICMP_TIME_EXCEEDED = 11
export const UNREACH_NET = 0
export const UNREACH_HOST = 1
export const UNREACH_PORT = 3
export const UNREACH_FRAG_NEEDED = 4

export interface ArpPacket {
  kind: 'arp'
  op: 1 | 2
  senderMac: Mac
  senderIp: number
  targetMac: Mac
  targetIp: number
}

/** Echo uses id/seq; error messages leave them 0 and carry the quoted datagram in `data`. */
export interface IcmpMessage {
  kind: 'icmp'
  type: number
  code: number
  checksum: number
  id: number
  seq: number
  data: Uint8Array
}

export interface UdpDatagram {
  kind: 'udp'
  srcPort: number
  dstPort: number
  checksum: number
  data: Uint8Array
}

export interface Ipv4Packet {
  kind: 'ipv4'
  tos: number
  id: number
  dontFragment: boolean
  ttl: number
  protocol: number
  checksum: number
  src: number
  dst: number
  payload: IcmpMessage | UdpDatagram
}

export interface EthernetFrame {
  id: number
  src: Mac
  dst: Mac
  etherType: number
  payload: ArpPacket | Ipv4Packet
}

export function internetChecksum(bytes: ArrayLike<number>): number {
  let sum = 0
  for (let i = 0; i < bytes.length; i += 2) {
    sum += (bytes[i] << 8) + (i + 1 < bytes.length ? bytes[i + 1] : 0)
  }
  while (sum > 0xffff) sum = (sum & 0xffff) + (sum >>> 16)
  return ~sum & 0xffff
}

const u16 = (n: number) => [(n >>> 8) & 255, n & 255]
const u32 = (n: number) => [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]

export const icmpSize = (m: IcmpMessage) => 8 + m.data.length
export const udpSize = (u: UdpDatagram) => 8 + u.data.length
export const ipv4Size = (p: Ipv4Packet) => 20 + (p.payload.kind === 'icmp' ? icmpSize(p.payload) : udpSize(p.payload))
/** Size as shown by Wireshark: Ethernet header + payload, no FCS. */
export const frameSize = (f: EthernetFrame) => 14 + (f.payload.kind === 'arp' ? 28 : ipv4Size(f.payload))
/** Bytes occupying the wire: frame + FCS padded to 64, plus preamble/SFD (8) and inter-frame gap (12). */
export const wireBytes = (f: EthernetFrame) => Math.max(frameSize(f) + 4, 64) + 20

export function serializeIcmp(m: IcmpMessage): number[] {
  return [m.type, m.code, ...u16(m.checksum), ...u16(m.id), ...u16(m.seq), ...m.data]
}

export function serializeUdp(u: UdpDatagram): number[] {
  return [...u16(u.srcPort), ...u16(u.dstPort), ...u16(udpSize(u)), ...u16(u.checksum), ...u.data]
}

export function serializeIpv4Header(p: Ipv4Packet): number[] {
  return [
    0x45, p.tos, ...u16(ipv4Size(p)), ...u16(p.id),
    p.dontFragment ? 0x40 : 0, 0, p.ttl, p.protocol, ...u16(p.checksum),
    ...u32(p.src), ...u32(p.dst),
  ]
}

export function serializeL4(p: Ipv4Packet): number[] {
  return p.payload.kind === 'icmp' ? serializeIcmp(p.payload) : serializeUdp(p.payload)
}

export function makeIcmp(f: Omit<IcmpMessage, 'kind' | 'checksum'>): IcmpMessage {
  const m: IcmpMessage = { kind: 'icmp', checksum: 0, ...f }
  return { ...m, checksum: internetChecksum(serializeIcmp(m)) }
}

export function makeUdp(f: Omit<UdpDatagram, 'kind' | 'checksum'>): UdpDatagram {
  // ponytail: UDP checksum left 0 (optional over IPv4, RFC 768); add pseudo-header checksum if a lab needs it
  return { kind: 'udp', checksum: 0, ...f }
}

export interface Ipv4Fields {
  src: number
  dst: number
  ttl: number
  id: number
  payload: IcmpMessage | UdpDatagram
  tos?: number
  dontFragment?: boolean
}

function withChecksum(p: Ipv4Packet): Ipv4Packet {
  const zeroed = { ...p, checksum: 0 }
  return { ...zeroed, checksum: internetChecksum(serializeIpv4Header(zeroed)) }
}

export function makeIpv4(f: Ipv4Fields): Ipv4Packet {
  return withChecksum({
    kind: 'ipv4',
    tos: f.tos ?? 0,
    id: f.id,
    dontFragment: f.dontFragment ?? true,
    ttl: f.ttl,
    protocol: f.payload.kind === 'icmp' ? IPPROTO_ICMP : IPPROTO_UDP,
    checksum: 0,
    src: f.src,
    dst: f.dst,
    payload: f.payload,
  })
}

export function withTtl(p: Ipv4Packet, ttl: number): Ipv4Packet {
  return withChecksum({ ...p, ttl })
}
