import React, { createContext, useContext, useState } from 'react'
import { useWebSocket } from '../hooks/useWebSocket'
import type { MetricsPayload, ConnectionStatus, ExperimentId } from '../types/metrics'

interface MetricsContextValue {
  metrics: MetricsPayload | null
  status: ConnectionStatus
  experiment: ExperimentId
  setExperiment: (id: ExperimentId) => void
}

const MetricsContext = createContext<MetricsContextValue | null>(null)

export function MetricsProvider({ children }: { children: React.ReactNode }) {
  const { metrics, status } = useWebSocket('ws://localhost:8080/ws/metrics')
  const [experiment, setExperiment] = useState<ExperimentId>(1)

  return (
    <MetricsContext.Provider value={{ metrics, status, experiment, setExperiment }}>
      {children}
    </MetricsContext.Provider>
  )
}

export function useMetrics(): MetricsContextValue {
  const ctx = useContext(MetricsContext)
  if (!ctx) throw new Error('useMetrics must be used inside MetricsProvider')
  return ctx
}
