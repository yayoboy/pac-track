import { describe, expect, it } from 'vitest'
import { Rng } from './rng'

describe('Rng', () => {
  it('is deterministic for a given seed', () => {
    const a = new Rng(42)
    const b = new Rng(42)
    const xs = Array.from({ length: 5 }, () => a.next())
    const ys = Array.from({ length: 5 }, () => b.next())
    expect(xs).toEqual(ys)
  })

  it('differs across seeds and stays in [0, 1)', () => {
    expect(new Rng(1).next()).not.toBe(new Rng(2).next())
    const r = new Rng(7)
    for (let i = 0; i < 1000; i++) {
      const v = r.next()
      expect(v).toBeGreaterThanOrEqual(0)
      expect(v).toBeLessThan(1)
    }
  })

  it('int() returns integers in [0, max)', () => {
    const r = new Rng(3)
    for (let i = 0; i < 1000; i++) {
      const v = r.int(10)
      expect(Number.isInteger(v)).toBe(true)
      expect(v).toBeGreaterThanOrEqual(0)
      expect(v).toBeLessThan(10)
    }
  })
})
