import { useEffect, useRef } from 'react'
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
  { key: 'pessimistic' as const, label: 'Pessimistic locking', color: '#10b981' }, // Used Green here for thematic match
]

function gridColor(): string {
  return 'rgba(255, 255, 255, 0.05)'
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
          tension: 0.4, // Smoother curved lines looks more premium
        })),
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 0 },
        plugins: {
          legend: { display: false },
          tooltip: {
            mode: 'index',
            intersect: false,
            backgroundColor: 'rgba(15, 17, 21, 0.9)',
            titleColor: '#ffffff',
            bodyColor: '#ffffff',
            borderColor: 'rgba(255,255,255,0.1)',
            borderWidth: 1
          },
        },
        scales: {
          x: {
            grid: { color: gc },
            ticks: { color: '#9ca3af', font: { size: 11, family: 'Inter' } },
          },
          y: {
            grid: { color: gc },
            ticks: {
              color: '#9ca3af',
              font: { size: 11, family: 'Inter' },
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
      <div className="chart-header">
        <h2 className="chart-title">
          Response Time — rolling 60s window
        </h2>
        <div className="chart-legend">
          {SERIES.map(({ label, color }) => (
            <div key={label} className="legend-item">
              <span className="legend-color" style={{ backgroundColor: color }} />
              <span className="legend-text">{label}</span>
            </div>
          ))}
        </div>
      </div>
      <div style={{ height: '224px' }}>
        <canvas ref={canvasRef} />
      </div>
    </PanelWrapper>
  )
}
