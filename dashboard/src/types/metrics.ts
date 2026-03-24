export interface ResponseTimes {
  no_lock: number[]
  optimistic: number[]
  pessimistic: number[]
}

export interface LockingStrategyData {
  oversells: number
  p95_ms: number
}

export interface LockingComparison {
  no_lock: LockingStrategyData
  optimistic: LockingStrategyData
  pessimistic: LockingStrategyData
}

export interface EventData {
  name: string
  demand: number
  success_rate: number
  p95_ms: number
}

export interface FairnessPolicyData {
  single_avg_position: number
  multi_avg_position: number
}

export interface FairnessData {
  single_tab_pct: number
  multi_tab_pct: number
  collapse_policy: FairnessPolicyData
  allow_policy: FairnessPolicyData
}

export interface MetricsPayload {
  queue_depth: number
  bookings_per_sec: number
  oversell_count: number
  ecs_tasks: number
  response_times: ResponseTimes
  locking_comparison: LockingComparison
  events: EventData[]
  fairness: FairnessData
}

export type ConnectionStatus = 'live' | 'mock'

export type PolicyToggle = 'collapse' | 'allow'

export type ExperimentId = 1 | 2 | 3 | 4 | 5

export const EXPERIMENT_PANELS: Record<ExperimentId, string[]> = {
  1: ['metric-cards', 'response-time-chart'],
  2: ['response-time-chart', 'locking-comparison'],
  3: ['response-time-chart', 'locking-comparison'],
  4: ['metric-cards', 'multi-event-table'],
  5: ['fairness-panel'],
}
