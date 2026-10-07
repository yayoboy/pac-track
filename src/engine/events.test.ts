import { describe, expect, it } from 'vitest'
import { EventLog } from './events'

describe('EventLog', () => {
  it('keeps the most recent events in order once full', () => {
    const log = new EventLog(3)
    for (let t = 0; t < 5; t++) log.push({ time: t, kind: 'tx', node: 'A' })
    expect(log.size).toBe(3)
    expect(log.total).toBe(5)
    expect(log.all().map((e) => e.time)).toEqual([2, 3, 4])
    expect(log.all().map((e) => e.seq)).toEqual([2, 3, 4])
  })
})
