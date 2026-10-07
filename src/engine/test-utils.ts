import { BROADCAST_MAC, type Mac } from './addr'
import { Node, type Interface } from './node'
import { ETHERTYPE_ARP, type EthernetFrame } from './pdu'
import { Sim } from './sim'

/** Minimal node that records every frame it receives and can emit raw frames. */
export class Probe extends Node {
  readonly got: { frame: EthernetFrame; iface: string; time: number }[] = []

  constructor(sim: Sim, id: string) {
    super(sim, id)
    this.addInterface('eth0')
  }

  override receive(frame: EthernetFrame, iface: Interface): void {
    this.got.push({ frame, iface: iface.name, time: this.sim.now })
  }

  sendRaw(dst: Mac = BROADCAST_MAC): EthernetFrame {
    const i = this.iface('eth0')
    const frame: EthernetFrame = {
      id: this.sim.nextId(),
      src: i.mac,
      dst,
      etherType: ETHERTYPE_ARP,
      payload: { kind: 'arp', op: 1, senderMac: i.mac, senderIp: 0, targetMac: '00:00:00:00:00:00', targetIp: 0 },
    }
    i.send(frame)
    return frame
  }
}
