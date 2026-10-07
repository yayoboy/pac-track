import { describe, expect, it } from 'vitest'
import {
  broadcastOf,
  formatIp,
  inSubnet,
  isGroupMac,
  macFromIndex,
  networkOf,
  parseCidr,
  parseIp,
  prefixMask,
} from './addr'

describe('IPv4', () => {
  it('round-trips dotted quads', () => {
    for (const ip of ['0.0.0.0', '10.0.0.1', '192.168.1.254', '255.255.255.255']) {
      expect(formatIp(parseIp(ip))).toBe(ip)
    }
    expect(parseIp('192.168.0.1')).toBe(0xc0a80001)
  })

  it('rejects malformed addresses with a descriptive error', () => {
    for (const bad of ['10.0.0.256', '10.0.0', '10.0.0.1.2', 'a.b.c.d', '01.2.3.4', ' 10.0.0.1', '', '-1.0.0.0']) {
      expect(() => parseIp(bad)).toThrow(/Invalid IPv4 address/)
    }
  })

  it('parses CIDR and rejects bad prefixes', () => {
    expect(parseCidr('10.0.0.5/24')).toEqual({ addr: parseIp('10.0.0.5'), prefix: 24 })
    expect(parseCidr('0.0.0.0/0')).toEqual({ addr: 0, prefix: 0 })
    for (const bad of ['10.0.0.1/33', '10.0.0.1', '10.0.0.1/', '10.0.0.1/ 24', '10.0.0.1/24/1', '10.0.0.1/024']) {
      expect(() => parseCidr(bad)).toThrow(/Invalid/)
    }
  })

  it('computes masks, networks and broadcasts', () => {
    expect(prefixMask(0)).toBe(0)
    expect(prefixMask(24)).toBe(0xffffff00)
    expect(prefixMask(32)).toBe(0xffffffff)
    expect(formatIp(networkOf(parseIp('10.0.0.5'), 30))).toBe('10.0.0.4')
    expect(formatIp(broadcastOf(parseIp('10.0.0.5'), 30))).toBe('10.0.0.7')
    expect(inSubnet(parseIp('192.168.1.77'), parseIp('192.168.1.0'), 24)).toBe(true)
    expect(inSubnet(parseIp('192.168.2.1'), parseIp('192.168.1.0'), 24)).toBe(false)
    expect(inSubnet(parseIp('8.8.8.8'), 0, 0)).toBe(true)
  })
})

describe('MAC', () => {
  it('generates locally administered unicast MACs', () => {
    expect(macFromIndex(11)).toBe('02:00:00:00:00:0b')
    expect(macFromIndex(0x01020304)).toBe('02:00:01:02:03:04')
    expect(isGroupMac(macFromIndex(1))).toBe(false)
  })

  it('detects broadcast/multicast', () => {
    expect(isGroupMac('ff:ff:ff:ff:ff:ff')).toBe(true)
    expect(isGroupMac('01:00:5e:00:00:01')).toBe(true)
  })
})
