import { BROADCAST_MAC, type Mac } from '../addr'
import type { Interface } from '../node'
import { ETHERTYPE_ARP, ETHERTYPE_IPV4, ICMP_DEST_UNREACH, UNREACH_HOST, type ArpPacket, type Ipv4Packet } from '../pdu'
import type { Timer } from '../scheduler'
import { S } from '../time'
import type { IpNode } from './ip-node'

export const ARP_CACHE_NS = 300 * S
export const ARP_RETRY_NS = 1 * S
export const ARP_RETRIES = 3
export const ARP_PENDING_MAX = 3

interface Pending {
  iface: Interface
  packets: Ipv4Packet[]
  tries: number
  timer?: Timer
}

export class Arp {
  private readonly cache = new Map<number, { mac: Mac; iface: Interface; expiresAt: number }>()
  private readonly pending = new Map<number, Pending>()

  constructor(private readonly node: IpNode) {}

  lookup(ip: number): Mac | undefined {
    const entry = this.cache.get(ip)
    if (!entry) return undefined
    if (this.node.sim.now >= entry.expiresAt) {
      this.cache.delete(ip)
      return undefined
    }
    return entry.mac
  }

  /** Sends `packet` to `nextHop` on `iface`, resolving its MAC first if needed. */
  send(iface: Interface, nextHop: number, packet: Ipv4Packet): void {
    const mac = this.lookup(nextHop)
    if (mac) {
      this.node.sendFrame(iface, mac, ETHERTYPE_IPV4, packet)
      return
    }
    const waiting = this.pending.get(nextHop)
    if (waiting) {
      if (waiting.packets.length < ARP_PENDING_MAX) waiting.packets.push(packet)
      else this.node.sim.emit({ kind: 'drop', node: this.node.id, iface: iface.name, packet, reason: 'arp-pending-full' })
      return
    }
    const fresh: Pending = { iface, packets: [packet], tries: 0 }
    this.pending.set(nextHop, fresh)
    this.request(nextHop, fresh)
  }

  handle(arp: ArpPacket, iface: Interface): void {
    const own = iface.ipv4?.addr
    const forUs = own !== undefined && arp.targetIp === own
    const known = this.cache.has(arp.senderIp)
    if (forUs || known) {
      this.cache.set(arp.senderIp, { mac: arp.senderMac, iface, expiresAt: this.node.sim.now + ARP_CACHE_NS })
    }
    if (forUs && arp.op === 1) {
      this.node.sendFrame(iface, arp.senderMac, ETHERTYPE_ARP, {
        kind: 'arp',
        op: 2,
        senderMac: iface.mac,
        senderIp: own,
        targetMac: arp.senderMac,
        targetIp: arp.senderIp,
      })
    }
    const waiting = this.pending.get(arp.senderIp)
    if (waiting && (forUs || known)) {
      this.pending.delete(arp.senderIp)
      waiting.timer?.cancel()
      for (const p of waiting.packets) this.node.sendFrame(waiting.iface, arp.senderMac, ETHERTYPE_IPV4, p)
    }
  }

  private request(ip: number, p: Pending): void {
    p.tries++
    this.node.sendFrame(p.iface, BROADCAST_MAC, ETHERTYPE_ARP, {
      kind: 'arp',
      op: 1,
      senderMac: p.iface.mac,
      senderIp: p.iface.ipv4?.addr ?? 0,
      targetMac: '00:00:00:00:00:00',
      targetIp: ip,
    })
    p.timer = this.node.sim.sched.after(ARP_RETRY_NS, () => {
      if (p.tries < ARP_RETRIES) {
        this.request(ip, p)
        return
      }
      this.pending.delete(ip)
      for (const packet of p.packets) {
        this.node.sim.emit({ kind: 'drop', node: this.node.id, iface: p.iface.name, packet, reason: 'arp-timeout' })
        this.node.icmpError(packet, ICMP_DEST_UNREACH, UNREACH_HOST)
      }
    })
  }
}
