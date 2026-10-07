import { Node, type Interface } from '../node'
import type { EthernetFrame } from '../pdu'
import type { Sim } from '../sim'

/** Layer-1 repeater. Collisions are not modelled (links are full duplex). */
export class Hub extends Node {
  constructor(sim: Sim, id: string, ports = 8) {
    super(sim, id)
    for (let i = 1; i <= ports; i++) this.addInterface(`p${i}`)
  }

  override receive(frame: EthernetFrame, inIf: Interface): void {
    for (const i of this.interfaces) if (i !== inIf && i.link) i.send(frame)
  }
}
