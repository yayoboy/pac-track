import { describe, expect, it } from 'vitest'
import { formatIp, parseIp } from '../addr'
import { Sim } from '../sim'
import { Probe } from '../test-utils'
import { RoutingTable } from './routing'

function setup() {
  const node = new Probe(new Sim(), 'R')
  node.addInterface('eth1')
  node.iface('eth0').ipv4 = { addr: parseIp('10.0.1.1'), prefix: 24 }
  node.iface('eth1').ipv4 = { addr: parseIp('10.0.12.1'), prefix: 30 }
  return { node, rt: new RoutingTable(() => node.interfaces) }
}

const hop = (rt: RoutingTable, dst: string) => {
  const h = rt.lookup(parseIp(dst))
  return h && `${h.iface.name} via ${formatIp(h.nextHop)}`
}

describe('RoutingTable', () => {
  it('routes connected subnets directly', () => {
    const { rt } = setup()
    expect(hop(rt, '10.0.1.50')).toBe('eth0 via 10.0.1.50')
    expect(hop(rt, '10.0.12.2')).toBe('eth1 via 10.0.12.2')
    expect(hop(rt, '8.8.8.8')).toBeUndefined()
  })

  it('resolves static routes through a connected next hop, longest prefix first', () => {
    const { rt } = setup()
    rt.addStatic('0.0.0.0/0', '10.0.1.254')
    rt.addStatic('10.0.2.0/24', '10.0.12.2')
    rt.addStatic('10.0.2.128/25', '10.0.1.253')
    expect(hop(rt, '8.8.8.8')).toBe('eth0 via 10.0.1.254')
    expect(hop(rt, '10.0.2.9')).toBe('eth1 via 10.0.12.2')
    expect(hop(rt, '10.0.2.200')).toBe('eth0 via 10.0.1.253')
  })

  it('ignores static routes whose next hop is not reachable', () => {
    const { rt } = setup()
    rt.addStatic('172.16.0.0/16', '192.168.0.1')
    expect(hop(rt, '172.16.5.5')).toBeUndefined()
  })

  it('drops connected routes of interfaces that are down', () => {
    const { node, rt } = setup()
    node.iface('eth0').up = false
    expect(hop(rt, '10.0.1.50')).toBeUndefined()
  })

  it('replaces a route with the same prefix', () => {
    const { rt } = setup()
    rt.addStatic('10.0.2.0/24', '10.0.12.2')
    rt.addStatic('10.0.2.7/24', '10.0.1.9') // normalised to 10.0.2.0/24
    expect(hop(rt, '10.0.2.1')).toBe('eth0 via 10.0.1.9')
  })

  it('rejects malformed input without changing the table', () => {
    const { rt } = setup()
    expect(() => rt.addStatic('10.0.2.0/33', '10.0.12.2')).toThrow(/Invalid CIDR/)
    expect(() => rt.addStatic('10.0.2.0/24', '10.0.12')).toThrow(/Invalid IPv4/)
    expect(hop(rt, '10.0.2.1')).toBeUndefined()
  })
})
