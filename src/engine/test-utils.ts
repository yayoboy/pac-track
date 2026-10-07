import { BROADCAST_MAC, type Mac } from './addr'
import { Node, type Interface } from './node'
import { ETHERTYPE_ARP, type EthernetFrame } from './pdu'
import { Sim } from './sim'
import { Host } from './devices/host'
import { Router } from './devices/router'
import { Switch } from './devices/switch'
import { Link } from './link'

/** Minimal node that records every frame it receives and can emit raw frames. */
export class Probe extends Node {
  readonly got: { frame: EthernetFrame; iface: string; time: number }[] = []

  constructor(sim: Sim, id: string) {
    super(sim, id)
    this.addInterface('eth0')
  }

  override receive(frame: EthernetFrame, iface: Interface): void {
    this.got.push({ frame, iface: iface.name, time: this.sim.now })
  }

  sendRaw(dst: Mac = BROADCAST_MAC): EthernetFrame {
    const i = this.iface('eth0')
    const frame: EthernetFrame = {
      id: this.sim.nextId(),
      src: i.mac,
      dst,
      etherType: ETHERTYPE_ARP,
      payload: { kind: 'arp', op: 1, senderMac: i.mac, senderIp: 0, targetMac: '00:00:00:00:00:00', targetIp: 0 },
    }
    i.send(frame)
    return frame
  }
}

/** A (10.0.0.1/24) and B (10.0.0.2/24) on one switch. */
export function lan(sim = new Sim()) {
  const sw = new Switch(sim, 'SW1')
  const a = new Host(sim, 'A')
  const b = new Host(sim, 'B')
  new Link(sim, a.iface('eth0'), sw.iface('Gi0/1'))
  new Link(sim, b.iface('eth0'), sw.iface('Gi0/2'))
  a.setIp('eth0', '10.0.0.1/24')
  b.setIp('eth0', '10.0.0.2/24')
  return { sim, sw, a, b }
}

/** H1 (10.0.1.10/24) — R1 (10.0.1.1 | 10.0.2.1) — H2 (10.0.2.10/24). */
export function routedPair(sim = new Sim()) {
  const h1 = new Host(sim, 'H1')
  const h2 = new Host(sim, 'H2')
  const r1 = new Router(sim, 'R1', 2)
  new Link(sim, h1.iface('eth0'), r1.iface('Gi0/0'))
  new Link(sim, r1.iface('Gi0/1'), h2.iface('eth0'))
  r1.setIp('Gi0/0', '10.0.1.1/24')
  r1.setIp('Gi0/1', '10.0.2.1/24')
  h1.setIp('eth0', '10.0.1.10/24')
  h1.setGateway('10.0.1.1')
  h2.setIp('eth0', '10.0.2.10/24')
  h2.setGateway('10.0.2.1')
  return { sim, h1, h2, r1 }
}

/** H1 10.0.1.10 — R1 (10.0.1.1 | 10.0.12.1/30) — R2 (10.0.12.2/30 | 10.0.2.1) — H2 10.0.2.10. */
export function twoRouters(sim = new Sim()) {
  const h1 = new Host(sim, 'H1')
  const h2 = new Host(sim, 'H2')
  const r1 = new Router(sim, 'R1', 2)
  const r2 = new Router(sim, 'R2', 2)
  new Link(sim, h1.iface('eth0'), r1.iface('Gi0/0'))
  new Link(sim, r1.iface('Gi0/1'), r2.iface('Gi0/0'))
  new Link(sim, r2.iface('Gi0/1'), h2.iface('eth0'))
  r1.setIp('Gi0/0', '10.0.1.1/24')
  r1.setIp('Gi0/1', '10.0.12.1/30')
  r2.setIp('Gi0/0', '10.0.12.2/30')
  r2.setIp('Gi0/1', '10.0.2.1/24')
  r1.routes.addStatic('10.0.2.0/24', '10.0.12.2')
  r2.routes.addStatic('10.0.1.0/24', '10.0.12.1')
  h1.setIp('eth0', '10.0.1.10/24')
  h1.setGateway('10.0.1.1')
  h2.setIp('eth0', '10.0.2.10/24')
  h2.setGateway('10.0.2.1')
  return { sim, h1, h2, r1, r2 }
}
