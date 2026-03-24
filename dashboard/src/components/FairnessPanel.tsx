import { useState } from 'react'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'
import type { PolicyToggle } from '../types/metrics'

function StackedBar({ singlePct, multiPct }: { singlePct: number; multiPct: number }) {
  return (
    <div>
      <div className="flex text-xs text-gray-500 dark:text-gray-400 justify-between mb-1">
        <span>Single-tab ({(singlePct * 100).toFixed(0)}%)</span>
        <span>Multi-tab ({(multiPct * 100).toFixed(0)}%)</span>
      </div>
      <div className="flex h-4 rounded-full overflow-hidden">
        <div
          className="bg-blue-500 transition-all duration-500"
          style={{ width: `${singlePct * 100}%` }}
        />
        <div
          className="bg-amber-400 transition-all duration-500"
          style={{ width: `${multiPct * 100}%` }}
        />
      </div>
    </div>
  )
}

export function FairnessPanel() {
  const { metrics } = useMetrics()
  const [policy, setPolicy] = useState<PolicyToggle>('collapse')
  if (!metrics) return null

  const f          = metrics.fairness
  const policyData = policy === 'collapse' ? f.collapse_policy : f.allow_policy

  return (
    <PanelWrapper panelId="fairness-panel">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300">
          Fairness Distribution (Exp 5)
        </h2>
        <div className="flex rounded-lg border border-gray-200 dark:border-gray-600 overflow-hidden text-xs">
          {(['collapse', 'allow'] as PolicyToggle[]).map(p => (
            <button
              key={p}
              onClick={() => setPolicy(p)}
              className={`px-3 py-1.5 font-medium transition-colors ${
                policy === p
                  ? 'bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900'
                  : 'bg-white dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
              }`}
            >
              {p === 'collapse' ? 'Collapse by IP' : 'Allow Multiple'}
            </button>
          ))}
        </div>
      </div>

      <div className="flex flex-col gap-5">
        <StackedBar singlePct={f.single_tab_pct} multiPct={f.multi_tab_pct} />

        <div className="grid grid-cols-2 gap-3">
          <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-3">
            <div className="text-xs text-blue-600 dark:text-blue-400 font-medium mb-1">
              Single-tab avg position
            </div>
            <div className="text-2xl font-bold text-blue-700 dark:text-blue-300 tabular-nums">
              #{policyData.single_avg_position.toLocaleString()}
            </div>
          </div>
          <div className="bg-amber-50 dark:bg-amber-900/20 rounded-lg p-3">
            <div className="text-xs text-amber-600 dark:text-amber-400 font-medium mb-1">
              Multi-tab avg position
            </div>
            <div className="text-2xl font-bold text-amber-700 dark:text-amber-300 tabular-nums">
              #{policyData.multi_avg_position.toLocaleString()}
            </div>
          </div>
        </div>

        <div className="flex items-center gap-4 text-xs text-gray-400 dark:text-gray-500">
          <span className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-sm bg-blue-500 inline-block" />
            Single-tab users
          </span>
          <span className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-sm bg-amber-400 inline-block" />
            Multi-tab users
          </span>
        </div>
      </div>
    </PanelWrapper>
  )
}
