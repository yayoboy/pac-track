import { inSubnet, networkOf, parseCidr, parseIp } from '../addr'
import type { Interface } from '../node'

interface StaticRoute {
  network: number
  prefix: number
  nextHop: number
}

export interface NextHop {
  iface: Interface
  nextHop: number
}

export class RoutingTable {
  private statics: StaticRoute[] = []

  constructor(private readonly interfaces: () => Interface[]) {}

  addStatic(cidr: string, nextHop: string): void {
    const { addr, prefix } = parseCidr(cidr)
    const route = { network: networkOf(addr, prefix), prefix, nextHop: parseIp(nextHop) }
    this.statics = this.statics.filter((r) => !(r.network === route.network && r.prefix === route.prefix))
    this.statics.push(route)
  }

  /** Longest-prefix match; on equal length a connected route wins. */
  lookup(dst: number): NextHop | undefined {
    const conn = this.connectedFor(dst)
    let best: StaticRoute | undefined
    for (const r of this.statics) {
      if (inSubnet(dst, r.network, r.prefix) && (!best || r.prefix > best.prefix)) best = r
    }
    if (conn && (!best || conn.prefix >= best.prefix)) return { iface: conn.iface, nextHop: dst }
    if (!best) return undefined
    const via = this.connectedFor(best.nextHop)
    return via ? { iface: via.iface, nextHop: best.nextHop } : undefined
  }

  private connectedFor(ip: number): { iface: Interface; prefix: number } | undefined {
    let best: { iface: Interface; prefix: number } | undefined
    for (const i of this.interfaces()) {
      if (i.up && i.ipv4 && inSubnet(ip, i.ipv4.addr, i.ipv4.prefix) && (!best || i.ipv4.prefix > best.prefix)) {
        best = { iface: i, prefix: i.ipv4.prefix }
      }
    }
    return best
  }
}
