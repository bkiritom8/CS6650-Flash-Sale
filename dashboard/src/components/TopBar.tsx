import React, { useState } from 'react'
import { useMetrics } from '../context/MetricsContext'
import type { ExperimentId } from '../types/metrics'

const EXPERIMENTS: { id: ExperimentId; label: string }[] = [
  { id: 1, label: 'Exp 1 — No-lock Baseline' },
  { id: 2, label: 'Exp 2 — Optimistic Locking' },
  { id: 3, label: 'Exp 3 — Pessimistic Locking' },
  { id: 4, label: 'Exp 4 — Multi-Event' },
  { id: 5, label: 'Exp 5 — Fairness Distribution' },
]

export function TopBar() {
  const { status, experiment, setExperiment } = useMetrics()
  const [dark, setDark] = useState(false)

  function toggleDark() {
    const next = !dark
    setDark(next)
    document.documentElement.classList.toggle('dark', next)
  }

  return (
    <header className="sticky top-0 z-10 flex items-center justify-between px-6 py-3 bg-white dark:bg-gray-900 border-b border-gray-200 dark:border-gray-700">
      <div className="flex items-center gap-3">
        <h1 className="text-base font-semibold text-gray-900 dark:text-gray-100 tracking-tight">
          Flash Sale Monitor
        </h1>
        <span
          className={`inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium ${
            status === 'live'
              ? 'bg-green-100 text-green-700'
              : 'bg-amber-100 text-amber-700'
          }`}
        >
          <span
            className={`w-1.5 h-1.5 rounded-full ${
              status === 'live' ? 'bg-green-500 animate-pulse' : 'bg-amber-400'
            }`}
          />
          {status === 'live' ? 'LIVE' : 'MOCK'}
        </span>
      </div>

      <div className="flex items-center gap-3">
        <button
          onClick={toggleDark}
          className="text-xs text-gray-500 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-100 border border-gray-200 dark:border-gray-600 rounded px-2 py-1"
        >
          {dark ? '☀ Light' : '☾ Dark'}
        </button>

        <div className="flex items-center gap-2">
          <label htmlFor="exp-select" className="text-xs text-gray-500 dark:text-gray-400">
            Experiment:
          </label>
          <select
            id="exp-select"
            value={experiment}
            onChange={e => setExperiment(Number(e.target.value) as ExperimentId)}
            className="text-sm border border-gray-200 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200 rounded-md px-2 py-1 text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            {EXPERIMENTS.map(({ id, label }) => (
              <option key={id} value={id}>{label}</option>
            ))}
          </select>
        </div>
      </div>
    </header>
  )
}
