import { describe, expect, it } from 'vitest'
import { Host } from '../devices/host'
import { Link } from '../link'
import { Sim } from '../sim'
import { routedPair } from '../test-utils'
import { MS, S } from '../time'
import { ping } from './ping'

/** Two hosts on a 10 Mb/s, 1 ms cable. */
function slowPair() {
  const sim = new Sim()
  const a = new Host(sim, 'A')
  const b = new Host(sim, 'B')
  new Link(sim, a.iface('eth0'), b.iface('eth0'), { bandwidthBps: 10e6, propDelayNs: 1 * MS })
  a.setIp('eth0', '10.0.0.1/24')
  b.setIp('eth0', '10.0.0.2/24')
  return { sim, a, b }
}

describe('ping', () => {
  it('measures RTT exactly: ARP + echo on the first probe, echo only afterwards', () => {
    const { sim, a } = slowPair()
    const p = ping(a, '10.0.0.2', { count: 2 })
    sim.run(12 * S)
    expect(p.result.done).toBe(true)
    expect(p.result.received).toBe(2)
    // ARP 84 B wire @10 Mb/s = 67.2 µs, echo 122 B = 97.6 µs, +1 ms each way
    expect(p.result.replies[0].rttNs).toBe(4_329_600)
    expect(p.result.replies[1].rttNs).toBe(2_195_200)
    expect(p.result.lines).toEqual([
      'PING 10.0.0.2 (10.0.0.2) 56(84) bytes of data.',
      '64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=4.330 ms',
      '64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=2.195 ms',
      '--- 10.0.0.2 ping statistics ---',
      '2 packets transmitted, 2 received, 0% packet loss',
    ])
  })

  it('pings its own address through loopback', () => {
    const { sim, a } = slowPair()
    const p = ping(a, '10.0.0.1', { count: 1 })
    sim.run(1 * MS)
    expect(p.result.replies).toEqual([{ seq: 1, from: '10.0.0.1', ttl: 64, rttNs: 0 }])
    expect(p.result.done).toBe(true)
    expect(sim.log.all().filter((e) => e.kind === 'tx')).toHaveLength(0)
  })

  it("gets a reply from a router's far-side interface", () => {
    const { sim, h1 } = routedPair()
    const p = ping(h1, '10.0.2.1', { count: 1 })
    sim.run(1 * S)
    expect(p.result.replies).toEqual([expect.objectContaining({ from: '10.0.2.1', ttl: 255 })])
  })

  it('reports TTL exceeded', () => {
    const { sim, h1 } = routedPair()
    const p = ping(h1, '10.0.2.10', { count: 1, ttl: 1 })
    sim.run(1 * S)
    expect(p.result.errors).toEqual([{ seq: 1, from: '10.0.1.1', type: 11, code: 0 }])
    expect(p.result.lines).toContain('From 10.0.1.1 icmp_seq=1 Time to live exceeded')
  })

  it('reports Destination Host Unreachable from a host with no cable', () => {
    const sim = new Sim()
    const h = new Host(sim, 'H')
    h.setIp('eth0', '10.0.0.1/24')
    const p = ping(h, '10.0.0.2', { count: 1 })
    sim.run(11 * S)
    expect(p.result.received).toBe(0)
    expect(p.result.lines).toContain('From 10.0.0.1 icmp_seq=1 Destination Host Unreachable')
    expect(p.result.lines.at(-1)).toBe('1 packets transmitted, 0 received, +1 errors, 100% packet loss')
    expect(sim.log.all().filter((e) => e.reason === 'no-link')).toHaveLength(3)
  })

  it('fails fast with no route', () => {
    const sim = new Sim()
    const h = new Host(sim, 'H')
    h.setIp('eth0', '10.0.0.1/24')
    const p = ping(h, '8.8.8.8')
    sim.run(1)
    expect(p.result.done).toBe(true)
    expect(p.result.transmitted).toBe(0)
    expect(p.result.lines[1]).toBe('ping: connect: Network is unreachable')
  })

  it('stop() ends early with statistics', () => {
    const { sim, a } = slowPair()
    const p = ping(a, '10.0.0.2', { count: 100 })
    sim.run(1500 * MS)
    p.stop()
    expect(p.result.done).toBe(true)
    expect(p.result.transmitted).toBe(2)
    expect(p.result.lines.at(-1)).toBe('2 packets transmitted, 2 received, 0% packet loss')
  })

  it('rejects an invalid target', () => {
    const { a } = slowPair()
    expect(() => ping(a, '10.0.0.300')).toThrow(/Invalid IPv4/)
  })
})
