import { useState } from 'react'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'
import type { PolicyToggle } from '../types/metrics'

function StackedBar({ singlePct, multiPct }: { singlePct: number; multiPct: number }) {
  return (
    <div>
      <div className="stacked-bar-labels">
        <span>Single-tab ({(singlePct * 100).toFixed(0)}%)</span>
        <span>Multi-tab ({(multiPct * 100).toFixed(0)}%)</span>
      </div>
      <div className="stacked-bar-container">
        <div
          className="stacked-part"
          style={{ width: `${singlePct * 100}%`, backgroundColor: '#3b82f6' }}
        />
        <div
          className="stacked-part"
          style={{ width: `${multiPct * 100}%`, backgroundColor: '#fbbf24' }}
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
      <div className="chart-header flex-between" style={{ marginBottom: '16px' }}>
        <h2 className="chart-title" style={{ margin: 0 }}>
          Fairness Distribution (Exp 5)
        </h2>
        <div className="tabs-container">
          {(['collapse', 'allow'] as PolicyToggle[]).map(p => (
            <button
              key={p}
              onClick={() => setPolicy(p)}
              className={`tab-btn ${policy === p ? 'active' : ''}`}
            >
              {p === 'collapse' ? 'Collapse by IP' : 'Allow Multiple'}
            </button>
          ))}
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
        <StackedBar singlePct={f.single_tab_pct} multiPct={f.multi_tab_pct} />

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
          <div className="stat-box stat-blue">
            <div className="stat-box-title">
              Single-tab avg position
            </div>
            <div className="stat-box-val">
              #{policyData.single_avg_position.toLocaleString()}
            </div>
          </div>
          <div className="stat-box stat-amber">
            <div className="stat-box-title">
              Multi-tab avg position
            </div>
            <div className="stat-box-val">
              #{policyData.multi_avg_position.toLocaleString()}
            </div>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '16px', fontSize: '0.75rem', color: 'var(--color-text-secondary)' }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
            <span style={{ width: '12px', height: '12px', borderRadius: '2px', backgroundColor: '#3b82f6' }} />
            Single-tab users
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
            <span style={{ width: '12px', height: '12px', borderRadius: '2px', backgroundColor: '#fbbf24' }} />
            Multi-tab users
          </span>
        </div>
      </div>
    </PanelWrapper>
  )
}
