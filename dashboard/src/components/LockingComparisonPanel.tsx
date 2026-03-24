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
const COLORS      = ['#ef4444', '#3b82f6', '#9ca3af']

function gridColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--color-grid').trim() || '#f3f4f6'
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
        animation: false,
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: { label: ctx => ` ${ctx.raw}${unit}` } },
        },
        scales: {
          x: {
            grid: { color: gc },
            ticks: { color: '#6b7280', font: { size: 11 }, callback: v => `${v}${unit}` },
          },
          y: {
            grid: { display: false },
            ticks: { color: '#374151', font: { size: 12 } },
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
      <h3 className="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-2">
        {title}
      </h3>
      <div className="h-24">
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
      <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-4">
        Locking Strategy Comparison
      </h2>
      <div className="flex flex-col gap-5">
        <HBarChart canvasId="chart-oversells" title="Oversell Count"   data={oversells} unit=""    />
        <div className="border-t border-gray-100 dark:border-gray-700" />
        <HBarChart canvasId="chart-p95"       title="P95 Latency (ms)" data={p95}       unit="ms" />
      </div>
    </PanelWrapper>
  )
}
