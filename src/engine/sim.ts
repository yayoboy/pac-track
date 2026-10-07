import { macFromIndex, type Mac } from './addr'
import { EventLog, type SimEvent } from './events'
import { Rng } from './rng'
import { Scheduler } from './scheduler'

export interface SimOptions {
  seed?: number
  logCapacity?: number
}

export class Sim {
  readonly sched = new Scheduler()
  readonly rng: Rng
  readonly log: EventLog
  private ids = 0
  private macs = 0

  constructor(opts: SimOptions = {}) {
    this.rng = new Rng(opts.seed ?? 1)
    this.log = new EventLog(opts.logCapacity)
  }

  get now(): number {
    return this.sched.now
  }

  nextId(): number {
    return ++this.ids
  }

  newMac(): Mac {
    return macFromIndex(++this.macs)
  }

  emit(e: Omit<SimEvent, 'seq' | 'time'>): void {
    this.log.push({ ...e, time: this.now })
  }

  run(durationNs: number): void {
    this.sched.runUntil(this.now + durationNs)
  }
}
