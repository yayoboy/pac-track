import { describe, expect, it } from 'vitest'
import { Link } from './link'
import { Sim } from './sim'
import { Probe } from './test-utils'
import { MS } from './time'

function pair(opts = {}) {
  const sim = new Sim()
  const a = new Probe(sim, 'A')
  const b = new Probe(sim, 'B')
  const link = new Link(sim, a.iface('eth0'), b.iface('eth0'), opts)
  return { sim, a, b, link }
}

const drops = (sim: Sim, reason: string) =>
  sim.log.all().filter((e) => e.kind === 'drop' && e.reason === reason).length

describe('Link', () => {
  it('first frame arrives at 672 + 500 ns, back-to-back frame at 1844 ns', () => {
    const { sim, a, b } = pair()
    a.sendRaw()
    a.sendRaw()
    sim.run(MS)
    expect(b.got.map((g) => g.time)).toEqual([1172, 1844])
    expect(sim.log.all()[0]).toMatchObject({ kind: 'tx', node: 'A', iface: 'eth0', time: 0 })
  })

  it('tail-drops when the queue is full', () => {
    const { sim, a, b } = pair({ queueLimit: 2 })
    for (let i = 0; i < 5; i++) a.sendRaw()
    sim.run(MS)
    expect(b.got).toHaveLength(3)
    expect(drops(sim, 'queue-full')).toBe(2)
  })

  it('drops lost frames at the receiver', () => {
    const { sim, a, b } = pair({ lossRate: 1 })
    a.sendRaw()
    sim.run(MS)
    expect(b.got).toHaveLength(0)
    expect(drops(sim, 'loss')).toBe(1)
  })

  it('drops when the link, interface or cable is missing/down', () => {
    const { sim, a, link } = pair()
    link.up = false
    a.sendRaw()
    a.iface('eth0').up = false
    a.sendRaw()
    const lonely = new Probe(sim, 'C')
    lonely.sendRaw()
    sim.run(MS)
    expect(drops(sim, 'link-down')).toBe(1)
    expect(drops(sim, 'iface-down')).toBe(1)
    expect(drops(sim, 'no-link')).toBe(1)
  })

  it('never transmits a frame in zero time', () => {
    const { sim, a, b } = pair({ bandwidthBps: 1e15, propDelayNs: 0 })
    a.sendRaw()
    sim.run(MS)
    expect(b.got[0].time).toBeGreaterThan(0)
  })

  it('rejects invalid link options', () => {
    for (const opts of [{ bandwidthBps: 0 }, { propDelayNs: -5 }, { lossRate: 1.5 }, { lossRate: -0.1 }, { queueLimit: -1 }, { bandwidthBps: NaN }]) {
      const sim = new Sim()
      const a = new Probe(sim, 'A')
      const b = new Probe(sim, 'B')
      expect(() => new Link(sim, a.iface('eth0'), b.iface('eth0'), opts)).toThrow(/Invalid link option/)
      expect(a.iface('eth0').link).toBeUndefined()
    }
  })

  it('refuses self-links and double connections', () => {
    const { sim, a, b } = pair()
    const c = new Probe(sim, 'C')
    a.addInterface('eth1')
    expect(() => new Link(sim, a.iface('eth1'), a.iface('eth0'))).toThrow(/itself/)
    expect(() => new Link(sim, c.iface('eth0'), b.iface('eth0'))).toThrow(/already connected/)
  })
})
