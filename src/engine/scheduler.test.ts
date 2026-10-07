import { describe, expect, it } from 'vitest'
import { Scheduler } from './scheduler'

describe('Scheduler', () => {
  it('runs events in time order and advances now', () => {
    const s = new Scheduler()
    const seen: string[] = []
    s.at(30, () => seen.push(`c@${s.now}`))
    s.at(10, () => seen.push(`a@${s.now}`))
    s.at(20, () => seen.push(`b@${s.now}`))
    s.runUntil(100)
    expect(seen).toEqual(['a@10', 'b@20', 'c@30'])
    expect(s.now).toBe(100)
  })

  it('keeps FIFO order for events at the same time', () => {
    const s = new Scheduler()
    const seen: number[] = []
    for (let i = 0; i < 5; i++) s.at(10, () => seen.push(i))
    s.runUntil(10)
    expect(seen).toEqual([0, 1, 2, 3, 4])
  })

  it('runs events scheduled during execution within the same window', () => {
    const s = new Scheduler()
    const seen: number[] = []
    s.at(5, () => s.after(0, () => seen.push(s.now)))
    s.runUntil(5)
    expect(seen).toEqual([5])
  })

  it('does not run events beyond the target time', () => {
    const s = new Scheduler()
    let ran = false
    s.at(11, () => (ran = true))
    s.runUntil(10)
    expect(ran).toBe(false)
    expect(s.now).toBe(10)
  })

  it('cancelled timers never fire and do not block later events', () => {
    const s = new Scheduler()
    const seen: string[] = []
    const t = s.at(5, () => seen.push('cancelled'))
    s.at(20, () => seen.push('late'))
    t.cancel()
    s.runUntil(10)
    expect(seen).toEqual([])
    expect(s.now).toBe(10)
    s.runUntil(20)
    expect(seen).toEqual(['late'])
  })

  it('rejects scheduling in the past', () => {
    const s = new Scheduler()
    s.runUntil(50)
    expect(() => s.at(10, () => {})).toThrow(/past/)
  })

  it('step() returns false when idle', () => {
    expect(new Scheduler().step()).toBe(false)
  })
})
