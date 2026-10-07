import type { EthernetFrame, Ipv4Packet } from './pdu'

export type EventKind = 'tx' | 'rx' | 'drop'

export type DropReason =
  | 'queue-full'
  | 'loss'
  | 'link-down'
  | 'iface-down'
  | 'no-link'
  | 'arp-timeout'
  | 'arp-pending-full'
  | 'no-route'
  | 'ttl-expired'
  | 'mtu-exceeded'

export interface SimEvent {
  seq: number
  time: number
  kind: EventKind
  node: string
  iface?: string
  frame?: EthernetFrame
  packet?: Ipv4Packet
  reason?: DropReason
}

/** Ring buffer: keeps the latest `capacity` events. */
export class EventLog {
  private buf: SimEvent[] = []
  private start = 0
  private seq = 0

  constructor(readonly capacity = 100_000) {}

  push(e: Omit<SimEvent, 'seq'>): void {
    const event = { ...e, seq: this.seq++ }
    if (this.buf.length < this.capacity) {
      this.buf.push(event)
    } else {
      this.buf[this.start] = event
      this.start = (this.start + 1) % this.capacity
    }
  }

  all(): SimEvent[] {
    return [...this.buf.slice(this.start), ...this.buf.slice(0, this.start)]
  }

  get size(): number {
    return this.buf.length
  }

  /** Events ever pushed, including those evicted. */
  get total(): number {
    return this.seq
  }
}
