import type { MetricsPayload } from '../types/metrics'

function clamp(val: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, val))
}

function drift(current: number, target: number, speed: number, noise: number): number {
  return current + (target - current) * speed + (Math.random() - 0.5) * noise
}

function rand(min: number, max: number): number {
  return min + Math.random() * (max - min)
}

const EVENTS = [
  { name: 'Taylor Swift NYC',  baseDemand: 1000, baseRate: 0.78 },
  { name: 'Bad Bunny LA',      baseDemand: 850,  baseRate: 0.85 },
  { name: 'Beyoncé Chicago',   baseDemand: 1200, baseRate: 0.62 },
  { name: 'Coldplay Boston',   baseDemand: 600,  baseRate: 0.92 },
  { name: 'Kendrick Lamar SF', baseDemand: 950,  baseRate: 0.71 },
]

export interface MockGenerator {
  next: () => MetricsPayload
}

export function createMockGenerator(): MockGenerator {
  let queueDepth = 500
  let queueTarget = 600
  let oversellCount = 0
  let singleTabPct = 0.63
  let tick = 0

  const rtHistory = {
    no_lock:     Array.from({ length: 20 }, () => rand(40, 55)),
    optimistic:  Array.from({ length: 20 }, () => rand(78, 95)),
    pessimistic: Array.from({ length: 20 }, () => rand(148, 170)),
  }

  return {
    next(): MetricsPayload {
      tick++

      if (tick % 30 === 0)  queueTarget = rand(800, 1600)
      if (tick % 30 === 15) queueTarget = rand(200, 500)

      queueDepth = clamp(drift(queueDepth, queueTarget, 0.1, 40), 0, 2000)
      const bookingsPerSec = Math.round(clamp(rand(20, 60) + queueDepth * 0.02, 0, 120))
      const ecsTasks = clamp(Math.ceil(queueDepth / 200) + Math.round(rand(-1, 1)), 1, 20)

      if (Math.random() < 0.15) oversellCount++

      rtHistory.no_lock.push(clamp(rand(40, 55) + queueDepth * 0.005, 30, 200))
      rtHistory.no_lock.shift()
      rtHistory.optimistic.push(clamp(rand(78, 95) + queueDepth * 0.01, 60, 300))
      rtHistory.optimistic.shift()
      rtHistory.pessimistic.push(clamp(rand(148, 170) + queueDepth * 0.015, 120, 500))
      rtHistory.pessimistic.shift()

      singleTabPct = clamp(drift(singleTabPct, 0.63, 0.02, 0.02), 0.45, 0.80)
      const multiTabPct = parseFloat((1 - singleTabPct).toFixed(2))

      const events = EVENTS.map(e => ({
        name: e.name,
        demand: Math.round(e.baseDemand + rand(-50, 50)),
        success_rate: parseFloat(clamp(e.baseRate + rand(-0.05, 0.05), 0, 1).toFixed(3)),
        p95_ms: Math.round(rand(100, 200)),
      }))

      return {
        queue_depth: Math.round(queueDepth),
        bookings_per_sec: bookingsPerSec,
        oversell_count: oversellCount,
        ecs_tasks: ecsTasks,
        response_times: {
          no_lock:     [...rtHistory.no_lock],
          optimistic:  [...rtHistory.optimistic],
          pessimistic: [...rtHistory.pessimistic],
        },
        locking_comparison: {
          no_lock:     { oversells: oversellCount,                    p95_ms: Math.round(rand(44, 52))   },
          optimistic:  { oversells: Math.round(oversellCount * 0.08), p95_ms: Math.round(rand(82, 96))   },
          pessimistic: { oversells: 0,                                p95_ms: Math.round(rand(152, 168)) },
        },
        events,
        fairness: {
          single_tab_pct: parseFloat(singleTabPct.toFixed(2)),
          multi_tab_pct:  multiTabPct,
          collapse_policy: {
            single_avg_position: Math.round(rand(340, 370)),
            multi_avg_position:  Math.round(rand(350, 375)),
          },
          allow_policy: {
            single_avg_position: Math.round(rand(400, 425)),
            multi_avg_position:  Math.round(rand(185, 215)),
          },
        },
      }
    },
  }
}
