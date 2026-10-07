import { BROADCAST_IP, BROADCAST_MAC, broadcastOf, inSubnet, networkOf, parseCidr, parseIp, type Mac } from '../addr'
import { Node, type Interface } from '../node'
import {
  ICMP_DEST_UNREACH,
  ICMP_ECHO_REPLY,
  ICMP_ECHO_REQUEST,
  ICMP_TIME_EXCEEDED,
  UNREACH_FRAG_NEEDED,
  UNREACH_NET,
  UNREACH_PORT,
  ipv4Size,
  makeIcmp,
  makeIpv4,
  makeUdp,
  serializeIpv4Header,
  serializeL4,
  withTtl,
  type ArpPacket,
  type EthernetFrame,
  type IcmpMessage,
  type Ipv4Packet,
  type UdpDatagram,
} from '../pdu'
import { Arp } from './arp'
import { RoutingTable } from './routing'

export type IcmpListener = (packet: Ipv4Packet, icmp: IcmpMessage) => void
export type UdpHandler = (packet: Ipv4Packet, udp: UdpDatagram) => void

/** A node with an IPv4 stack: ARP, routing, ICMP and UDP. */
export abstract class IpNode extends Node {
  readonly arp = new Arp(this)
  readonly routes = new RoutingTable(() => this.interfaces)
  defaultTtl = 64
  protected forwarding = false
  private ipId = 0
  private readonly udp = new Map<number, UdpHandler>()
  private readonly icmpListeners = new Set<IcmpListener>()

  setIp(ifName: string, cidr: string): void {
    const iface = this.iface(ifName)
    const { addr, prefix } = parseCidr(cidr)
    if (prefix < 31 && (addr === networkOf(addr, prefix) || addr === broadcastOf(addr, prefix))) {
      throw new Error(`${cidr} is a network or broadcast address`)
    }
    for (const other of this.interfaces) {
      if (other !== iface && other.ipv4 && inSubnet(addr, other.ipv4.addr, Math.min(prefix, other.ipv4.prefix))) {
        throw new Error(`${cidr} overlaps with ${other.name}`)
      }
    }
    iface.ipv4 = { addr, prefix }
  }

  setGateway(ip: string): void {
    this.routes.addStatic('0.0.0.0/0', ip)
  }

  ownsIp(ip: number): boolean {
    return this.interfaces.some((i) => i.ipv4?.addr === ip)
  }

  /** Source address this node would use to reach `dst`, if routable. */
  sourceFor(dst: number): number | undefined {
    if (this.ownsIp(dst)) return dst
    return this.routes.lookup(dst)?.iface.ipv4?.addr
  }

  bindUdp(port: number, handler: UdpHandler): () => void {
    if (this.udp.has(port)) throw new Error(`UDP port ${port} already in use`)
    this.udp.set(port, handler)
    return () => this.udp.delete(port)
  }

  onIcmp(listener: IcmpListener): () => void {
    this.icmpListeners.add(listener)
    return () => this.icmpListeners.delete(listener)
  }

  /** Originates a packet. Returns false when there is no route to `dst`. */
  sendPacket(dst: number, payload: IcmpMessage | UdpDatagram, ttl = this.defaultTtl): boolean {
    const src = this.sourceFor(dst)
    if (src === undefined) return false
    this.output(makeIpv4({ src, dst, ttl, id: this.nextIpId(), payload }))
    return true
  }

  sendUdp(dst: number, srcPort: number, dstPort: number, data: Uint8Array, ttl?: number): boolean {
    return this.sendPacket(dst, makeUdp({ srcPort, dstPort, data }), ttl)
  }

  sendFrame(iface: Interface, dst: Mac, etherType: number, payload: ArpPacket | Ipv4Packet): void {
    iface.send({ id: this.sim.nextId(), src: iface.mac, dst, etherType, payload })
  }

  /** Sends an ICMP error about `orig` back to its source (never about ICMP errors). */
  icmpError(orig: Ipv4Packet, type: number, code: number): void {
    const l4 = orig.payload
    if (l4.kind === 'icmp' && l4.type !== ICMP_ECHO_REQUEST && l4.type !== ICMP_ECHO_REPLY) return
    if (orig.dst === BROADCAST_IP || orig.src === 0) return
    const src = this.sourceFor(orig.src)
    if (src === undefined) return
    const quote = new Uint8Array([...serializeIpv4Header(orig), ...serializeL4(orig).slice(0, 8)])
    this.output(
      makeIpv4({
        src,
        dst: orig.src,
        ttl: this.defaultTtl,
        id: this.nextIpId(),
        payload: makeIcmp({ type, code, id: 0, seq: 0, data: quote }),
      }),
    )
  }

  override receive(frame: EthernetFrame, iface: Interface): void {
    if (frame.dst !== iface.mac && frame.dst !== BROADCAST_MAC) return
    if (frame.payload.kind === 'arp') this.arp.handle(frame.payload, iface)
    else this.input(frame.payload, iface)
  }

  private input(p: Ipv4Packet, iface: Interface): void {
    const subnetBroadcast = iface.ipv4 && p.dst === broadcastOf(iface.ipv4.addr, iface.ipv4.prefix)
    if (this.ownsIp(p.dst) || p.dst === BROADCAST_IP || subnetBroadcast) {
      this.deliver(p)
      return
    }
    if (!this.forwarding) return
    if (p.ttl <= 1) {
      this.sim.emit({ kind: 'drop', node: this.id, iface: iface.name, packet: p, reason: 'ttl-expired' })
      this.icmpError(p, ICMP_TIME_EXCEEDED, 0)
      return
    }
    this.output(withTtl(p, p.ttl - 1))
  }

  private output(p: Ipv4Packet): void {
    if (this.ownsIp(p.dst)) {
      this.sim.sched.after(0, () => this.deliver(p))
      return
    }
    const hop = this.routes.lookup(p.dst)
    if (!hop) {
      this.sim.emit({ kind: 'drop', node: this.id, packet: p, reason: 'no-route' })
      this.icmpError(p, ICMP_DEST_UNREACH, UNREACH_NET)
      return
    }
    if (ipv4Size(p) > hop.iface.mtu) {
      // ponytail: no IPv4 fragmentation; non-DF oversize packets are dropped
      this.sim.emit({ kind: 'drop', node: this.id, iface: hop.iface.name, packet: p, reason: 'mtu-exceeded' })
      if (p.dontFragment) this.icmpError(p, ICMP_DEST_UNREACH, UNREACH_FRAG_NEEDED)
      return
    }
    this.arp.send(hop.iface, hop.nextHop, p)
  }

  private deliver(p: Ipv4Packet): void {
    const l4 = p.payload
    if (l4.kind === 'icmp') {
      if (l4.type === ICMP_ECHO_REQUEST && p.dst !== BROADCAST_IP) {
        // Reply from the address that was pinged, like Linux and IOS do.
        this.output(
          makeIpv4({
            src: p.dst,
            dst: p.src,
            ttl: this.defaultTtl,
            id: this.nextIpId(),
            payload: makeIcmp({ type: ICMP_ECHO_REPLY, code: 0, id: l4.id, seq: l4.seq, data: l4.data }),
          }),
        )
      }
      for (const listener of this.icmpListeners) listener(p, l4)
      return
    }
    const handler = this.udp.get(l4.dstPort)
    if (handler) handler(p, l4)
    else if (p.dst !== BROADCAST_IP) this.icmpError(p, ICMP_DEST_UNREACH, UNREACH_PORT)
  }

  private nextIpId(): number {
    this.ipId = (this.ipId + 1) & 0xffff
    return this.ipId
  }
}
