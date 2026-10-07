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
    if (!this.interfaces().some((i) => i.ipv4 && inSubnet(route.nextHop, i.ipv4.addr, i.ipv4.prefix))) {
      throw new Error(`Next hop ${nextHop} is not in a connected subnet`)
    }
    this.statics = this.statics.filter((r) => !(r.network === route.network && r.prefix === route.prefix))
    this.statics.push(route)
  }

  /**
   * Longest-prefix match; on equal length a connected route wins.
   * Static routes whose next hop is not currently reachable are skipped (as if withdrawn from the RIB).
   */
  lookup(dst: number): NextHop | undefined {
    const conn = this.connectedFor(dst)
    let best: NextHop | undefined
    let bestPrefix = -1
    for (const r of this.statics) {
      if (!inSubnet(dst, r.network, r.prefix) || r.prefix <= bestPrefix) continue
      const via = this.connectedFor(r.nextHop)
      if (!via) continue
      best = { iface: via.iface, nextHop: r.nextHop }
      bestPrefix = r.prefix
    }
    if (conn && conn.prefix >= bestPrefix) return { iface: conn.iface, nextHop: dst }
    return best
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
