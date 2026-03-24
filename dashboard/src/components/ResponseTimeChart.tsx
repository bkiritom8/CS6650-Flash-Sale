import React, { useEffect, useRef } from 'react'
import {
  Chart,
  LineController,
  LineElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Tooltip,
} from 'chart.js'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'

Chart.register(LineController, LineElement, PointElement, LinearScale, CategoryScale, Tooltip)

const X_LABELS = Array.from({ length: 20 }, (_, i) => `${(19 - i) * -3}s`)

const SERIES = [
  { key: 'no_lock'     as const, label: 'No-lock baseline',   color: '#ef4444' },
  { key: 'optimistic'  as const, label: 'Optimistic locking',  color: '#3b82f6' },
  { key: 'pessimistic' as const, label: 'Pessimistic locking', color: '#9ca3af' },
]

function gridColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--color-grid').trim() || '#f3f4f6'
}

export function ResponseTimeChart() {
  const { metrics } = useMetrics()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const chartRef  = useRef<Chart | null>(null)

  useEffect(() => {
    if (!canvasRef.current) return
    const gc = gridColor()

    chartRef.current = new Chart(canvasRef.current, {
      type: 'line',
      data: {
        labels: X_LABELS,
        datasets: SERIES.map(({ label, color }) => ({
          label,
          data: Array(20).fill(null),
          borderColor: color,
          backgroundColor: 'transparent',
          borderWidth: 2,
          pointRadius: 0,
          tension: 0.3,
        })),
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: {
          legend: { display: false },
          tooltip: { mode: 'index', intersect: false },
        },
        scales: {
          x: {
            grid: { color: gc },
            ticks: { color: '#6b7280', font: { size: 11 } },
          },
          y: {
            grid: { color: gc },
            ticks: {
              color: '#6b7280',
              font: { size: 11 },
              callback: v => `${v}ms`,
            },
            beginAtZero: true,
          },
        },
      },
    })
    return () => chartRef.current?.destroy()
  }, [])

  useEffect(() => {
    if (!chartRef.current || !metrics) return
    const rt = metrics.response_times
    chartRef.current.data.datasets[0].data = rt.no_lock
    chartRef.current.data.datasets[1].data = rt.optimistic
    chartRef.current.data.datasets[2].data = rt.pessimistic
    chartRef.current.update('none')
  }, [metrics])

  return (
    <PanelWrapper panelId="response-time-chart">
      <div className="mb-3">
        <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
          Response Time — rolling 60s window
        </h2>
        <div className="flex flex-wrap gap-4">
          {SERIES.map(({ label, color }) => (
            <div key={label} className="flex items-center gap-1.5">
              <span
                className="w-5 h-0.5 inline-block rounded"
                style={{ backgroundColor: color }}
              />
              <span className="text-xs text-gray-500 dark:text-gray-400">{label}</span>
            </div>
          ))}
        </div>
      </div>
      <div className="h-56">
        <canvas ref={canvasRef} />
      </div>
    </PanelWrapper>
  )
}
