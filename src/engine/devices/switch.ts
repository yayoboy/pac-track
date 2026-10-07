import { isGroupMac, type Mac } from '../addr'
import { Node, type Interface } from '../node'
import type { EthernetFrame } from '../pdu'
import type { Sim } from '../sim'
import { S } from '../time'

export const MAC_AGING_NS = 300 * S

interface MacEntry {
  iface: Interface
  seen: number
}

/** Transparent learning bridge (802.1D without STP). */
export class Switch extends Node {
  private readonly table = new Map<Mac, MacEntry>()

  constructor(sim: Sim, id: string, ports = 8) {
    super(sim, id)
    for (let i = 1; i <= ports; i++) this.addInterface(`Gi0/${i}`)
  }

  lookup(mac: Mac): Interface | undefined {
    const entry = this.table.get(mac)
    if (!entry) return undefined
    if (this.sim.now - entry.seen > MAC_AGING_NS) {
      this.table.delete(mac)
      return undefined
    }
    return entry.iface
  }

  override receive(frame: EthernetFrame, inIf: Interface): void {
    if (!isGroupMac(frame.src)) this.table.set(frame.src, { iface: inIf, seen: this.sim.now })
    const out = isGroupMac(frame.dst) ? undefined : this.lookup(frame.dst)
    if (out) {
      if (out !== inIf) out.send(frame)
      return
    }
    for (const i of this.interfaces) if (i !== inIf && i.link) i.send(frame)
  }
}
