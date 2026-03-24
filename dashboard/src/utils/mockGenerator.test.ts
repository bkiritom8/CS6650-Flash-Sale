import { describe, it, expect } from 'vitest'
import { createMockGenerator } from './mockGenerator'

describe('createMockGenerator', () => {
  it('returns a payload with all required keys', () => {
    const gen = createMockGenerator()
    const payload = gen.next()
    expect(payload).toHaveProperty('queue_depth')
    expect(payload).toHaveProperty('bookings_per_sec')
    expect(payload).toHaveProperty('oversell_count')
    expect(payload).toHaveProperty('ecs_tasks')
    expect(payload).toHaveProperty('response_times')
    expect(payload).toHaveProperty('locking_comparison')
    expect(payload).toHaveProperty('events')
    expect(payload).toHaveProperty('fairness')
  })

  it('queue_depth stays within realistic bounds over 100 ticks', () => {
    const gen = createMockGenerator()
    for (let i = 0; i < 100; i++) {
      const p = gen.next()
      expect(p.queue_depth).toBeGreaterThanOrEqual(0)
      expect(p.queue_depth).toBeLessThanOrEqual(2000)
    }
  })

  it('ecs_tasks stays within 1–20', () => {
    const gen = createMockGenerator()
    for (let i = 0; i < 50; i++) {
      const p = gen.next()
      expect(p.ecs_tasks).toBeGreaterThanOrEqual(1)
      expect(p.ecs_tasks).toBeLessThanOrEqual(20)
    }
  })

  it('response_times arrays have exactly 20 elements', () => {
    const gen = createMockGenerator()
    const p = gen.next()
    expect(p.response_times.no_lock).toHaveLength(20)
    expect(p.response_times.optimistic).toHaveLength(20)
    expect(p.response_times.pessimistic).toHaveLength(20)
  })

  it('fairness percentages sum to 1.0', () => {
    const gen = createMockGenerator()
    const p = gen.next()
    expect(p.fairness.single_tab_pct + p.fairness.multi_tab_pct).toBeCloseTo(1.0, 2)
  })

  it('event success_rate is in [0, 1]', () => {
    const gen = createMockGenerator()
    const p = gen.next()
    expect(p.events.length).toBeGreaterThan(0)
    p.events.forEach(e => {
      expect(e.success_rate).toBeGreaterThanOrEqual(0)
      expect(e.success_rate).toBeLessThanOrEqual(1)
    })
  })
})
