import { useEffect, useRef } from 'react'
import {
  Chart,
  BarController,
  BarElement,
  LinearScale,
  CategoryScale,
  Tooltip,
} from 'chart.js'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'

Chart.register(BarController, BarElement, LinearScale, CategoryScale, Tooltip)

const STRATEGIES = ['No-lock', 'Optimistic', 'Pessimistic']
const COLORS      = ['#ef4444', '#3b82f6', '#10b981'] // Replaced pessimistic color with green

function gridColor(): string {
  return 'rgba(255, 255, 255, 0.05)'
}

interface HBarChartProps {
  canvasId: string
  title: string
  data: number[]
  unit: string
}

function HBarChart({ canvasId, title, data, unit }: HBarChartProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const chartRef  = useRef<Chart | null>(null)

  useEffect(() => {
    if (!canvasRef.current) return
    const gc = gridColor()

    chartRef.current = new Chart(canvasRef.current, {
      type: 'bar',
      data: {
        labels: STRATEGIES,
        datasets: [{
          data,
          backgroundColor: COLORS,
          borderRadius: 4,
          barThickness: 18,
        }],
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 0 },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: { label: ctx => ` ${ctx.raw}${unit}` },
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
            ticks: { color: '#9ca3af', font: { size: 11, family: 'Inter' }, callback: v => `${v}${unit}` },
          },
          y: {
            grid: { display: false },
            ticks: { color: '#d1d5db', font: { size: 12, family: 'Inter' } },
          },
        },
      },
    })
    return () => chartRef.current?.destroy()
  }, [])

  useEffect(() => {
    if (!chartRef.current) return
    chartRef.current.data.datasets[0].data = data
    chartRef.current.update('none')
  }, [data])

  return (
    <div>
      <h3 className="chart-title text-secondary" style={{ textTransform: 'uppercase', letterSpacing: '0.05em', fontSize: '0.75rem', marginBottom: '8px' }}>
        {title}
      </h3>
      <div className="bar-chart-container">
        <canvas ref={canvasRef} id={canvasId} />
      </div>
    </div>
  )
}

export function LockingComparisonPanel() {
  const { metrics } = useMetrics()
  if (!metrics) return null

  const lc = metrics.locking_comparison
  const oversells = [lc.no_lock.oversells, lc.optimistic.oversells, lc.pessimistic.oversells]
  const p95       = [lc.no_lock.p95_ms,    lc.optimistic.p95_ms,    lc.pessimistic.p95_ms]

  return (
    <PanelWrapper panelId="locking-comparison">
      <div className="chart-header" style={{ marginBottom: '16px' }}>
        <h2 className="chart-title" style={{ margin: 0 }}>
          Locking Strategy Comparison
        </h2>
      </div>
      <div className="flex-col" style={{ gap: '20px' }}>
        <HBarChart canvasId="chart-oversells" title="Oversell Count"   data={oversells} unit=""    />
        <div className="section-divider" />
        <HBarChart canvasId="chart-p95"       title="P95 Latency (ms)" data={p95}       unit="ms" />
      </div>
    </PanelWrapper>
  )
}
