import { describe, expect, it } from 'vitest'
import { Link } from '../link'
import { Sim } from '../sim'
import { Probe } from '../test-utils'
import { MS, S } from '../time'
import { Hub } from './hub'
import { Switch } from './switch'

function star<T extends Hub | Switch>(sim: Sim, dev: T, names: string[]) {
  return names.map((n, i) => {
    const p = new Probe(sim, n)
    new Link(sim, p.iface('eth0'), dev.interfaces[i])
    return p
  })
}

describe('Hub', () => {
  it('repeats every frame to all other connected ports', () => {
    const sim = new Sim()
    const [a, b, c] = star(sim, new Hub(sim, 'HUB'), ['A', 'B', 'C'])
    a.sendRaw(b.iface('eth0').mac)
    sim.run(MS)
    expect(a.got).toHaveLength(0)
    expect(b.got).toHaveLength(1)
    expect(c.got).toHaveLength(1)
  })
})

describe('Switch', () => {
  it('floods unknown destinations, then forwards learned ones only', () => {
    const sim = new Sim()
    const sw = new Switch(sim, 'SW1')
    const [a, b, c] = star(sim, sw, ['A', 'B', 'C'])
    a.sendRaw() // broadcast: learn A, flood
    sim.run(MS)
    expect(b.got).toHaveLength(1)
    expect(c.got).toHaveLength(1)
    expect(sw.lookup(a.iface('eth0').mac)).toBe(sw.iface('Gi0/1'))

    b.sendRaw(a.iface('eth0').mac) // known unicast: only A
    sim.run(MS)
    expect(a.got).toHaveLength(1)
    expect(c.got).toHaveLength(1)
    expect(sw.lookup(b.iface('eth0').mac)).toBe(sw.iface('Gi0/2'))
  })

  it('ages out MAC entries after 300 s', () => {
    const sim = new Sim()
    const sw = new Switch(sim, 'SW1')
    const [a] = star(sim, sw, ['A', 'B'])
    a.sendRaw()
    sim.run(MS)
    sim.run(301 * S)
    expect(sw.lookup(a.iface('eth0').mac)).toBeUndefined()
  })

  it('stays bounded in a layer-2 loop (broadcast storm)', () => {
    const sim = new Sim({ logCapacity: 1000 })
    const sw1 = new Switch(sim, 'SW1')
    const sw2 = new Switch(sim, 'SW2')
    new Link(sim, sw1.iface('Gi0/1'), sw2.iface('Gi0/1'))
    new Link(sim, sw1.iface('Gi0/2'), sw2.iface('Gi0/2'))
    const a = new Probe(sim, 'A')
    new Link(sim, a.iface('eth0'), sw1.iface('Gi0/3'))
    a.sendRaw()
    sim.run(10 * MS)
    expect(sim.log.size).toBe(1000)
    expect(sim.log.total).toBeGreaterThan(1000)
  })
})
