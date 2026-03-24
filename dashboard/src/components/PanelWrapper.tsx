import { type ReactNode } from 'react'
import { useMetrics } from '../context/MetricsContext'
import { EXPERIMENT_PANELS } from '../types/metrics'

interface PanelWrapperProps {
  panelId: string
  children: ReactNode
  className?: string
}

export function PanelWrapper({ panelId, children, className = '' }: PanelWrapperProps) {
  const { experiment, setExperiment } = useMetrics()
  const active = EXPERIMENT_PANELS[experiment].includes(panelId)

  const handleActivate = () => {
    if (active) return
    // Find the first experiment that includes this panel
    const targetExp = (Object.entries(EXPERIMENT_PANELS) as [string, string[]][])
      .find(([, panels]) => panels.includes(panelId))

    if (targetExp) {
      // Cast to generic number then ExperimentId since we know keys are valid
      setExperiment(Number(targetExp[0]) as any)
    }
  }

  return (
    <div
      onClick={active ? undefined : handleActivate}
      className={`glass-panel animate-fade-in ${className}`}
      style={{
        padding: '24px',
        opacity: active ? 1 : 0.4,
        cursor: active ? 'default' : 'pointer',
        transition: 'all 0.3s ease',
        position: 'relative'
      }}
    >
      {!active && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 10, cursor: 'pointer' }} />
      )}
      {children}
    </div>
  )
}
