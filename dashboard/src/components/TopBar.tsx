
import { useMetrics } from '../context/MetricsContext'
import type { ExperimentId } from '../types/metrics'
import type { ViewState } from '../App'

const EXPERIMENTS: { id: ExperimentId; label: string }[] = [
  { id: 1, label: 'Exp 1 — No-lock Baseline' },
  { id: 2, label: 'Exp 2 — Optimistic Locking' },
  { id: 3, label: 'Exp 3 — Pessimistic Locking' },
  { id: 4, label: 'Exp 4 — Multi-Event' },
  { id: 5, label: 'Exp 5 — Fairness Distribution' },
]

export function TopBar({ currentView, onViewChange, isAdmin }: { currentView: ViewState, onViewChange: (v: ViewState) => void, isAdmin: boolean }) {
  const { status, experiment, setExperiment } = useMetrics()
  // No longer toggle 'dark' class on body since we are default dark theme now!
  // BUT we will keep the button to show we replaced the logic to be default dark.
  
  return (
    <header className="topbar">
      <div style={{ display: 'flex', alignItems: 'center', gap: '24px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          <h1 className="topbar-title text-gradient">
            Flash Sale Monitor
          </h1>
          <span className={`status-badge ${status !== 'live' ? 'mock' : ''}`}>
            <span className={`status-dot ${status !== 'live' ? 'mock' : ''}`} />
            {status === 'live' ? 'LIVE' : 'MOCK'}
          </span>
        </div>

        {/* Navigation Tabs */}
        <div className="tabs-container" style={{ display: 'flex', border: '1px solid var(--color-panel-border)', borderRadius: '8px', overflow: 'hidden' }}>
          <button 
            className={`tab-btn ${currentView === 'user' ? 'active' : ''}`}
            onClick={() => onViewChange('user')}
          >
            Fan View
          </button>

          {!isAdmin && (
            <button 
              className={`tab-btn ${(currentView === 'analytics' || currentView === 'experiments') ? 'active' : ''}`}
              onClick={() => onViewChange('analytics')}
            >
              Admin Control
            </button>
          )}

          {isAdmin && (
            <>
              <button 
                className={`tab-btn ${currentView === 'analytics' ? 'active' : ''}`}
                onClick={() => onViewChange('analytics')}
              >
                Analytics
              </button>
              <button 
                className={`tab-btn ${currentView === 'experiments' ? 'active' : ''}`}
                onClick={() => onViewChange('experiments')}
              >
                Experiments
              </button>
            </>
          )}
        </div>
      </div>

      <div className="topbar-controls">
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <label htmlFor="exp-select" style={{ fontSize: '0.75rem', color: 'var(--color-text-secondary)' }}>
            Experiment:
          </label>
          <select
            id="exp-select"
            value={experiment}
            onChange={e => setExperiment(Number(e.target.value) as ExperimentId)}
            className="select-base"
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
