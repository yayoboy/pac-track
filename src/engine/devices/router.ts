import { IpNode } from '../l3/ip-node'
import type { Sim } from '../sim'

export class Router extends IpNode {
  constructor(sim: Sim, id: string, ports = 4) {
    super(sim, id)
    this.forwarding = true
    this.defaultTtl = 255
    for (let i = 0; i < ports; i++) this.addInterface(`Gi0/${i}`)
  }
}
