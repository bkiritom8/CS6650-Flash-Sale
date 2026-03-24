import { PanelWrapper } from './PanelWrapper'
import { MetricCard } from './MetricCard'
import { useMetrics } from '../context/MetricsContext'

export function MetricCards() {
  const { metrics } = useMetrics()
  if (!metrics) return null

  return (
    <PanelWrapper panelId="metric-cards">
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-6">
        <MetricCard label="Queue Depth" value={metrics.queue_depth.toLocaleString()} />
        <MetricCard label="Bookings / sec" value={metrics.bookings_per_sec} />
        <MetricCard label="Oversell Events" value={metrics.oversell_count} />
        <MetricCard label="ECS Tasks" value={metrics.ecs_tasks} />
      </div>
    </PanelWrapper>
  )
}
