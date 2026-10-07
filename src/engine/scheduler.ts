export interface Timer {
  cancel(): void
}

interface Entry {
  time: number
  seq: number
  fn: () => void
  cancelled: boolean
}

/** Min-heap of events ordered by (time, insertion seq) for deterministic ties. */
export class Scheduler {
  now = 0
  private heap: Entry[] = []
  private seq = 0

  at(time: number, fn: () => void): Timer {
    if (time < this.now) throw new Error(`Cannot schedule in the past (${time} < ${this.now})`)
    const entry: Entry = { time, seq: this.seq++, fn, cancelled: false }
    this.push(entry)
    return { cancel: () => (entry.cancelled = true) }
  }

  after(delay: number, fn: () => void): Timer {
    return this.at(this.now + delay, fn)
  }

  /** Runs the next live event. Returns false when nothing is pending. */
  step(): boolean {
    const entry = this.peek()
    if (!entry) return false
    this.pop()
    this.now = entry.time
    entry.fn()
    return true
  }

  runUntil(time: number): void {
    for (let e = this.peek(); e && e.time <= time; e = this.peek()) this.step()
    if (time > this.now) this.now = time
  }

  private peek(): Entry | undefined {
    while (this.heap.length > 0 && this.heap[0].cancelled) this.pop()
    return this.heap[0]
  }

  private less(a: Entry, b: Entry): boolean {
    return a.time < b.time || (a.time === b.time && a.seq < b.seq)
  }

  private push(entry: Entry): void {
    const h = this.heap
    h.push(entry)
    let i = h.length - 1
    while (i > 0) {
      const parent = (i - 1) >> 1
      if (!this.less(h[i], h[parent])) break
      ;[h[i], h[parent]] = [h[parent], h[i]]
      i = parent
    }
  }

  private pop(): Entry | undefined {
    const h = this.heap
    if (h.length === 0) return undefined
    const top = h[0]
    const last = h.pop()!
    if (h.length > 0) {
      h[0] = last
      let i = 0
      for (;;) {
        const l = 2 * i + 1
        const r = l + 1
        let m = i
        if (l < h.length && this.less(h[l], h[m])) m = l
        if (r < h.length && this.less(h[r], h[m])) m = r
        if (m === i) break
        ;[h[i], h[m]] = [h[m], h[i]]
        i = m
      }
    }
    return top
  }
}
