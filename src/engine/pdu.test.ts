import { describe, expect, it } from 'vitest'
import { parseIp } from './addr'
import {
  ETHERTYPE_ARP,
  ETHERTYPE_IPV4,
  ICMP_ECHO_REQUEST,
  type EthernetFrame,
  frameSize,
  internetChecksum,
  ipv4Size,
  makeIcmp,
  makeIpv4,
  makeUdp,
  serializeIcmp,
  serializeIpv4Header,
  wireBytes,
  withTtl,
} from './pdu'

const echo = (dataLen = 56) =>
  makeIcmp({ type: ICMP_ECHO_REQUEST, code: 0, id: 1, seq: 1, data: new Uint8Array(dataLen) })

describe('checksums', () => {
  it('matches the classic IPv4 header example (0xb861)', () => {
    // 4500 0073 0000 4000 4011 xxxx c0a8 0001 c0a8 00c7
    const p = makeIpv4({
      src: parseIp('192.168.0.1'),
      dst: parseIp('192.168.0.199'),
      ttl: 64,
      id: 0,
      payload: makeUdp({ srcPort: 1, dstPort: 2, data: new Uint8Array(87) }),
    })
    expect(ipv4Size(p)).toBe(0x73)
    expect(p.checksum).toBe(0xb861)
  })

  it('produces headers that verify to zero', () => {
    const p = makeIpv4({ src: parseIp('10.0.0.1'), dst: parseIp('10.0.0.2'), ttl: 64, id: 7, payload: echo() })
    expect(internetChecksum(serializeIpv4Header(p))).toBe(0)
    expect(internetChecksum(serializeIcmp(p.payload as ReturnType<typeof echo>))).toBe(0)
  })

  it('withTtl returns a new packet with a valid checksum', () => {
    const p = makeIpv4({ src: parseIp('10.0.0.1'), dst: parseIp('10.0.0.2'), ttl: 64, id: 7, payload: echo() })
    const q = withTtl(p, 63)
    expect(p.ttl).toBe(64)
    expect(q.ttl).toBe(63)
    expect(q.checksum).not.toBe(p.checksum)
    expect(internetChecksum(serializeIpv4Header(q))).toBe(0)
  })

  it('handles odd-length input', () => {
    expect(internetChecksum([0x01])).toBe(0xfeff)
  })
})

describe('sizes', () => {
  it('ICMP echo with 56 B data is 98 B on Ethernet, 122 B on the wire', () => {
    const p = makeIpv4({ src: 1, dst: 2, ttl: 64, id: 1, payload: echo() })
    const f: EthernetFrame = { id: 1, src: '02:00:00:00:00:01', dst: '02:00:00:00:00:02', etherType: ETHERTYPE_IPV4, payload: p }
    expect(ipv4Size(p)).toBe(84)
    expect(frameSize(f)).toBe(98)
    expect(wireBytes(f)).toBe(122)
  })

  it('ARP frame is 42 B, padded to 64 + 20 B overhead on the wire', () => {
    const f: EthernetFrame = {
      id: 1,
      src: '02:00:00:00:00:01',
      dst: 'ff:ff:ff:ff:ff:ff',
      etherType: ETHERTYPE_ARP,
      payload: { kind: 'arp', op: 1, senderMac: '02:00:00:00:00:01', senderIp: 1, targetMac: '00:00:00:00:00:00', targetIp: 2 },
    }
    expect(frameSize(f)).toBe(42)
    expect(wireBytes(f)).toBe(84)
  })
})
