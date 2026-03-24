import { type ReactNode } from 'react'
import { useMetrics } from '../context/MetricsContext'
import { EXPERIMENT_PANELS } from '../types/metrics'

interface PanelWrapperProps {
  panelId: string
  children: ReactNode
  className?: string
}

export function PanelWrapper({ panelId, children, className = '' }: PanelWrapperProps) {
  const { experiment } = useMetrics()
  const active = EXPERIMENT_PANELS[experiment].includes(panelId)

  return (
    <div
      className={`
        bg-white dark:bg-gray-800
        border border-gray-200 dark:border-gray-700
        rounded-xl p-5
        transition-opacity duration-300
        ${active ? 'opacity-100' : 'opacity-30'}
        ${className}
      `}
    >
      {children}
    </div>
  )
}
