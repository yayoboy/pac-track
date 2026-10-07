import type { DropReason } from './events'
import type { Interface } from './node'
import { type EthernetFrame, wireBytes } from './pdu'
import type { Sim } from './sim'
import { S } from './time'

export interface LinkOptions {
  bandwidthBps: number
  propDelayNs: number
  lossRate: number
  queueLimit: number
}

/** 1 Gb/s copper, ~100 m. */
export const DEFAULT_LINK: LinkOptions = { bandwidthBps: 1e9, propDelayNs: 500, lossRate: 0, queueLimit: 1000 }

interface Direction {
  queue: EthernetFrame[]
  busy: boolean
}

/** Full-duplex point-to-point link with a FIFO tail-drop queue per direction. */
export class Link {
  up = true
  readonly opts: LinkOptions
  private readonly dirs: Map<Interface, Direction>

  constructor(
    readonly sim: Sim,
    readonly a: Interface,
    readonly b: Interface,
    opts: Partial<LinkOptions> = {},
  ) {
    if (a.node === b.node) throw new Error('Cannot connect a node to itself')
    if (a.link || b.link) throw new Error(`Interface already connected: ${a.link ? a.id : b.id}`)
    const o = (this.opts = { ...DEFAULT_LINK, ...opts })
    if (!(o.bandwidthBps > 0 && o.propDelayNs >= 0 && o.lossRate >= 0 && o.lossRate <= 1 && o.queueLimit >= 0)) {
      throw new Error(`Invalid link options: ${JSON.stringify(opts)}`)
    }
    this.dirs = new Map([
      [a, { queue: [], busy: false }],
      [b, { queue: [], busy: false }],
    ])
    a.link = this
    b.link = this
  }

  peer(i: Interface): Interface {
    return i === this.a ? this.b : this.a
  }

  transmit(from: Interface, frame: EthernetFrame): void {
    if (!this.up) return this.drop(from, frame, 'link-down')
    const dir = this.dirs.get(from)!
    if (!dir.busy) return this.startTx(from, dir, frame)
    if (dir.queue.length >= this.opts.queueLimit) return this.drop(from, frame, 'queue-full')
    dir.queue.push(frame)
  }

  private startTx(from: Interface, dir: Direction, frame: EthernetFrame): void {
    dir.busy = true
    this.sim.emit({ kind: 'tx', node: from.node.id, iface: from.name, frame })
    // At least 1 ns, so time always advances (a zero-time loop would never end).
    const txNs = Math.max(1, Math.round((wireBytes(frame) * 8 * S) / this.opts.bandwidthBps))
    this.sim.sched.after(txNs, () => {
      const to = this.peer(from)
      const lost = this.opts.lossRate > 0 && this.sim.rng.next() < this.opts.lossRate
      this.sim.sched.after(this.opts.propDelayNs, () => this.arrive(to, frame, lost))
      const next = dir.queue.shift()
      if (next) this.startTx(from, dir, next)
      else dir.busy = false
    })
  }

  private arrive(to: Interface, frame: EthernetFrame, lost: boolean): void {
    if (lost) return this.drop(to, frame, 'loss')
    if (!this.up || !to.up || !to.node.powered) return this.drop(to, frame, 'link-down')
    this.sim.emit({ kind: 'rx', node: to.node.id, iface: to.name, frame })
    to.node.receive(frame, to)
  }

  private drop(at: Interface, frame: EthernetFrame, reason: DropReason): void {
    this.sim.emit({ kind: 'drop', node: at.node.id, iface: at.name, frame, reason })
  }
}
