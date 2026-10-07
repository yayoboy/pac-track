/** MAC address, lowercase colon-separated: "02:00:00:00:00:0b". */
export type Mac = string

export const BROADCAST_MAC: Mac = 'ff:ff:ff:ff:ff:ff'
export const BROADCAST_IP = 0xffffffff

const OCTET = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/
const PREFIX = /^(3[0-2]|[12]?\d)$/

export function parseIp(s: string): number {
  const parts = s.split('.')
  if (parts.length !== 4 || !parts.every((p) => OCTET.test(p))) {
    throw new Error(`Invalid IPv4 address: "${s}"`)
  }
  return parts.reduce((acc, p) => acc * 256 + Number(p), 0)
}

export function formatIp(n: number): string {
  return [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.')
}

export interface Cidr {
  addr: number
  prefix: number
}

export function parseCidr(s: string): Cidr {
  const parts = s.split('/')
  if (parts.length !== 2 || !PREFIX.test(parts[1])) throw new Error(`Invalid CIDR: "${s}"`)
  return { addr: parseIp(parts[0]), prefix: Number(parts[1]) }
}

export function prefixMask(prefix: number): number {
  return prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0
}

export function networkOf(addr: number, prefix: number): number {
  return (addr & prefixMask(prefix)) >>> 0
}

export function broadcastOf(addr: number, prefix: number): number {
  return (networkOf(addr, prefix) | ~prefixMask(prefix)) >>> 0
}

export function inSubnet(addr: number, network: number, prefix: number): boolean {
  return networkOf(addr, prefix) === networkOf(network, prefix)
}

export function macFromIndex(i: number): Mac {
  const bytes = [0x02, 0x00, (i >>> 24) & 255, (i >>> 16) & 255, (i >>> 8) & 255, i & 255]
  return bytes.map((b) => b.toString(16).padStart(2, '0')).join(':')
}

/** True for broadcast and multicast MACs (I/G bit set). */
export function isGroupMac(mac: Mac): boolean {
  return (parseInt(mac.slice(0, 2), 16) & 1) === 1
}
