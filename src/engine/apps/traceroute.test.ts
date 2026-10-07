import { describe, expect, it } from 'vitest'
import { Sim } from '../sim'
import { twoRouters } from '../test-utils'
import { S } from '../time'
import { ping } from './ping'
import { traceroute } from './traceroute'

describe('traceroute', () => {
  it('lists every hop up to the destination', () => {
    const { sim, h1 } = twoRouters()
    const t = traceroute(h1, '10.0.2.10')
    sim.run(30 * S)
    expect(t.result.done).toBe(true)
    expect(t.result.reached).toBe(true)
    expect(t.result.hops.map((h) => h.probes.map((p) => p.from))).toEqual([
      ['10.0.1.1', '10.0.1.1', '10.0.1.1'],
      ['10.0.12.2', '10.0.12.2', '10.0.12.2'],
      ['10.0.2.10', '10.0.2.10', '10.0.2.10'],
    ])
    expect(t.result.lines[0]).toBe('traceroute to 10.0.2.10 (10.0.2.10), 30 hops max, 60 byte packets')
    expect(t.result.lines[1]).toMatch(/^ 1  10\.0\.1\.1 \(10\.0\.1\.1\)  \d+\.\d{3} ms  \d+\.\d{3} ms  \d+\.\d{3} ms$/)
  })

  it('marks unreachable networks with !N and stops', () => {
    const { sim, h1 } = twoRouters()
    const t = traceroute(h1, '10.0.9.9')
    sim.run(30 * S)
    expect(t.result.hops).toHaveLength(2)
    expect(t.result.reached).toBe(true)
    expect(t.result.lines[2]).toMatch(/^ 2  10\.0\.1\.1 \(10\.0\.1\.1\)  \d+\.\d{3} ms !N/)
  })

  it('prints * for unanswered probes and honours maxHops', () => {
    const { sim, h1, h2 } = twoRouters()
    h2.iface('eth0').link!.opts.lossRate = 1
    const t = traceroute(h1, '10.0.2.10', { maxHops: 3, waitNs: 1 * S })
    sim.run(30 * S)
    expect(t.result.done).toBe(true)
    expect(t.result.reached).toBe(false)
    expect(t.result.lines[3]).toBe(' 3  * * *')
  })

  it('ping across two routers sees TTL 62', () => {
    const { sim, h1 } = twoRouters()
    const p = ping(h1, '10.0.2.10', { count: 1 })
    sim.run(1 * S)
    expect(p.result.replies[0].ttl).toBe(62)
  })

  it('keeps concurrent traceroutes from the same node apart', () => {
    const { sim, h1 } = twoRouters()
    // Resolve the gateway first: 6 simultaneous probes would overflow the 3-packet ARP queue.
    ping(h1, '10.0.1.1', { count: 1 })
    sim.run(1 * S)
    const good = traceroute(h1, '10.0.2.10')
    const bad = traceroute(h1, '10.0.9.9')
    sim.run(60 * S)
    expect(good.result.hops.map((h) => h.probes[0].from)).toEqual(['10.0.1.1', '10.0.12.2', '10.0.2.10'])
    expect(bad.result.hops.map((h) => h.probes[0].from)).toEqual(['10.0.1.1', '10.0.1.1'])
    expect(bad.result.lines[2]).toMatch(/!N/)
  })

  it('rejects invalid options synchronously', () => {
    const { h1 } = twoRouters()
    for (const opts of [{ maxHops: 0 }, { maxHops: 256 }, { probes: 0 }, { waitNs: 0 }, { firstPort: 70000 }]) {
      expect(() => traceroute(h1, '10.0.2.10', opts)).toThrow(/Invalid traceroute option/)
    }
  })
})

describe('determinism', () => {
  const run = (seed: number) => {
    const { sim, h1 } = twoRouters(new Sim({ seed }))
    ping(h1, '10.0.2.10', { count: 3 })
    traceroute(h1, '10.0.2.10')
    sim.run(30 * S)
    return sim.log.all().map((e) => `${e.time} ${e.kind} ${e.node} ${e.iface ?? ''} ${e.frame?.id ?? ''} ${e.reason ?? ''}`)
  }

  it('same seed and topology produce an identical event log', () => {
    const first = run(5)
    expect(first.length).toBeGreaterThan(50)
    expect(run(5)).toEqual(first)
  })
})
