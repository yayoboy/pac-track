import type { Mac } from './addr'
import type { Link } from './link'
import type { EthernetFrame } from './pdu'
import type { Sim } from './sim'

export class Interface {
  link?: Link
  up = true
  mtu = 1500
  ipv4?: { addr: number; prefix: number }

  constructor(
    readonly node: Node,
    readonly name: string,
    readonly mac: Mac,
  ) {}

  get id(): string {
    return `${this.node.id}/${this.name}`
  }

  send(frame: EthernetFrame): void {
    const reason = !this.node.powered || !this.up ? 'iface-down' : !this.link ? 'no-link' : undefined
    if (reason) {
      this.node.sim.emit({ kind: 'drop', node: this.node.id, iface: this.name, frame, reason })
      return
    }
    this.link!.transmit(this, frame)
  }
}

export abstract class Node {
  readonly interfaces: Interface[] = []
  powered = true

  constructor(
    readonly sim: Sim,
    readonly id: string,
    public name: string = id,
  ) {}

  addInterface(name: string): Interface {
    const iface = new Interface(this, name, this.sim.newMac())
    this.interfaces.push(iface)
    return iface
  }

  iface(name: string): Interface {
    const iface = this.interfaces.find((i) => i.name === name)
    if (!iface) throw new Error(`${this.id} has no interface ${name}`)
    return iface
  }

  abstract receive(frame: EthernetFrame, iface: Interface): void
}
