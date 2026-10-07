import { IpNode } from '../l3/ip-node'
import type { Sim } from '../sim'

export class Host extends IpNode {
  constructor(sim: Sim, id: string) {
    super(sim, id)
    this.addInterface('eth0')
  }
}
