import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'
import type { EventData } from '../types/metrics'

function statusBadgeLabel(rate: number): string {
  if (rate > 0.90) return 'Healthy'
  if (rate >= 0.75) return 'Degraded'
  return 'Contention'
}

function EventRow({ event }: { event: EventData }) {
  const badgeLabel = statusBadgeLabel(event.success_rate)
  const pct   = (event.success_rate * 100).toFixed(1)

  return (
    <tr className="event-row">
      <td className="event-cell event-name">
        {event.name}
      </td>
      <td className="event-cell event-stat">
        {event.demand.toLocaleString()}
      </td>
      <td className="event-cell event-stat">
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <div className="progress-bg">
            <div
              className="progress-fill"
              style={{ width: `${pct}%`, backgroundColor: event.success_rate < 0.75 ? '#ef4444' : event.success_rate < 0.9 ? '#f59e0b' : '#10b981' }}
            />
          </div>
          <span style={{ fontSize: '0.875rem' }}>{pct}%</span>
        </div>
      </td>
      <td className="event-cell event-stat">
        {event.p95_ms}ms
      </td>
      <td className="event-cell">
        <span className="status-badge" style={{ 
          background: event.success_rate < 0.75 ? 'rgba(239, 68, 68, 0.1)' : event.success_rate < 0.9 ? 'rgba(245, 158, 11, 0.1)' : 'rgba(16, 185, 129, 0.1)',
          color: event.success_rate < 0.75 ? '#ef4444' : event.success_rate < 0.9 ? '#f59e0b' : '#10b981',
          borderColor: event.success_rate < 0.75 ? 'rgba(239, 68, 68, 0.2)' : event.success_rate < 0.9 ? 'rgba(245, 158, 11, 0.2)' : 'rgba(16, 185, 129, 0.2)'
        }}>
          {badgeLabel}
        </span>
      </td>
    </tr>
  )
}

const HEADERS = ['Event', 'Demand', 'Success Rate', 'P95', 'Status']

export function MultiEventTable() {
  const { metrics } = useMetrics()
  if (!metrics) return null

  return (
    <PanelWrapper panelId="multi-event-table">
      <div className="chart-header">
        <h2 className="chart-title">
          Multi-Event Flash Sales (Exp 4)
        </h2>
      </div>
      <div className="table-container">
        <table>
          <thead>
            <tr>
              {HEADERS.map(h => (
                <th
                  key={h}
                  style={{ textTransform: 'uppercase', fontSize: '0.75rem', letterSpacing: '0.05em' }}
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {metrics.events.map(event => (
              <EventRow key={event.name} event={event} />
            ))}
          </tbody>
        </table>
      </div>
    </PanelWrapper>
  )
}
