import { describe, expect, it } from 'vitest'
import { formatIp, parseIp } from '../addr'
import { Host } from '../devices/host'
import { ICMP_ECHO_REQUEST, type IcmpMessage, type Ipv4Packet, makeIcmp } from '../pdu'
import { Sim } from '../sim'
import { lan, routedPair } from '../test-utils'
import { MS, S } from '../time'
import type { IpNode } from './ip-node'

const echo = (dataLen = 56) =>
  makeIcmp({ type: ICMP_ECHO_REQUEST, code: 0, id: 9, seq: 1, data: new Uint8Array(dataLen) })

function icmpSeen(node: IpNode) {
  const seen: { from: string; type: number; code: number; ttl: number }[] = []
  node.onIcmp((p: Ipv4Packet, m: IcmpMessage) => seen.push({ from: formatIp(p.src), type: m.type, code: m.code, ttl: p.ttl }))
  return seen
}

describe('ARP + ICMP on a LAN', () => {
  it('resolves MACs both ways and answers echo requests', () => {
    const { sim, a, b } = lan()
    const seen = icmpSeen(a)
    expect(a.sendPacket(parseIp('10.0.0.2'), echo())).toBe(true)
    sim.run(MS)
    expect(a.arp.lookup(parseIp('10.0.0.2'))).toBe(b.iface('eth0').mac)
    expect(b.arp.lookup(parseIp('10.0.0.1'))).toBe(a.iface('eth0').mac)
    expect(seen).toEqual([{ from: '10.0.0.2', type: 0, code: 0, ttl: 64 }])
  })

  it('reports host unreachable to itself after 3 unanswered ARP requests', () => {
    const { sim, a } = lan()
    const seen = icmpSeen(a)
    a.sendPacket(parseIp('10.0.0.99'), echo())
    sim.run(2 * S)
    expect(seen).toEqual([])
    sim.run(2 * S)
    expect(seen).toEqual([{ from: '10.0.0.1', type: 3, code: 1, ttl: 64 }])
    const arpTx = sim.log.all().filter((e) => e.kind === 'tx' && e.node === 'A' && e.frame?.payload.kind === 'arp')
    expect(arpTx).toHaveLength(3)
    expect(sim.log.all().some((e) => e.reason === 'arp-timeout')).toBe(true)
  })

  it('answers closed UDP ports with port unreachable', () => {
    const { sim, a } = lan()
    const seen = icmpSeen(a)
    a.sendUdp(parseIp('10.0.0.2'), 40000, 9, new Uint8Array(4))
    sim.run(MS)
    expect(seen).toEqual([{ from: '10.0.0.2', type: 3, code: 3, ttl: 64 }])
  })

  it('delivers UDP to bound ports', () => {
    const { sim, a, b } = lan()
    const got: number[] = []
    b.bindUdp(5000, (_p, u) => got.push(u.data.length))
    expect(() => b.bindUdp(5000, () => {})).toThrow(/in use/)
    a.sendUdp(parseIp('10.0.0.2'), 40000, 5000, new Uint8Array(10))
    sim.run(MS)
    expect(got).toEqual([10])
  })

  it('reports fragmentation needed for DF packets above the MTU', () => {
    const { sim, a } = lan()
    const seen = icmpSeen(a)
    a.sendPacket(parseIp('10.0.0.2'), echo(1500))
    sim.run(MS)
    expect(seen).toEqual([{ from: '10.0.0.1', type: 3, code: 4, ttl: 64 }])
  })
})

describe('routing through a router', () => {
  it('forwards and decrements TTL', () => {
    const { sim, h1 } = routedPair()
    const seen = icmpSeen(h1)
    h1.sendPacket(parseIp('10.0.2.10'), echo())
    sim.run(MS)
    expect(seen).toEqual([{ from: '10.0.2.10', type: 0, code: 0, ttl: 63 }])
  })

  it('sends time exceeded when TTL runs out', () => {
    const { sim, h1 } = routedPair()
    const seen = icmpSeen(h1)
    h1.sendPacket(parseIp('10.0.2.10'), echo(), 1)
    sim.run(MS)
    expect(seen).toEqual([{ from: '10.0.1.1', type: 11, code: 0, ttl: 255 }])
  })

  it('sends net unreachable when the router has no route', () => {
    const { sim, h1 } = routedPair()
    const seen = icmpSeen(h1)
    h1.sendPacket(parseIp('192.168.9.9'), echo())
    sim.run(MS)
    expect(seen).toEqual([{ from: '10.0.1.1', type: 3, code: 0, ttl: 255 }])
  })

  it('refuses to originate without a route', () => {
    const sim = new Sim()
    const h = new Host(sim, 'H')
    h.setIp('eth0', '10.0.0.1/24')
    expect(h.sendPacket(parseIp('8.8.8.8'), echo())).toBe(false)
  })
})

describe('configuration validation', () => {
  it('rejects bad addresses and leaves the interface unchanged', () => {
    const sim = new Sim()
    const h = new Host(sim, 'H')
    h.setIp('eth0', '10.0.0.1/24')
    for (const bad of ['10.0.0.256/24', '10.0.0.1/33', '10.0.0.1', 'abc']) {
      expect(() => h.setIp('eth0', bad)).toThrow(/Invalid/)
    }
    expect(() => h.setIp('eth0', '10.0.0.0/24')).toThrow(/network or broadcast/)
    expect(() => h.setIp('eth0', '10.0.0.255/24')).toThrow(/network or broadcast/)
    expect(h.iface('eth0').ipv4).toEqual({ addr: parseIp('10.0.0.1'), prefix: 24 })
  })

  it('rejects overlapping subnets on one node', () => {
    const { r1 } = routedPair()
    expect(() => r1.setIp('Gi0/1', '10.0.1.2/24')).toThrow(/overlaps/)
    expect(r1.iface('Gi0/1').ipv4?.addr).toBe(parseIp('10.0.2.1'))
  })

  it('rejects a gateway outside connected subnets', () => {
    const sim = new Sim()
    const h = new Host(sim, 'H')
    h.setIp('eth0', '10.0.0.1/24')
    expect(() => h.setGateway('10.0.1.1')).toThrow(/not in a connected subnet/)
    expect(h.routes.lookup(parseIp('8.8.8.8'))).toBeUndefined()
  })
})
