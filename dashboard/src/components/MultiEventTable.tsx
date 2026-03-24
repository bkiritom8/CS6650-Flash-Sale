import React from 'react'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'
import type { EventData } from '../types/metrics'

function statusBadge(rate: number): { label: string; classes: string } {
  if (rate > 0.90) return { label: 'Healthy',    classes: 'bg-green-100 text-green-700' }
  if (rate >= 0.75) return { label: 'Degraded',  classes: 'bg-amber-100 text-amber-700' }
  return               { label: 'Contention', classes: 'bg-red-100 text-red-700'   }
}

function EventRow({ event }: { event: EventData }) {
  const badge = statusBadge(event.success_rate)
  const pct   = (event.success_rate * 100).toFixed(1)

  return (
    <tr className="border-t border-gray-100 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-750 transition-colors">
      <td className="py-2.5 px-4 text-sm font-medium text-gray-800 dark:text-gray-200">
        {event.name}
      </td>
      <td className="py-2.5 px-4 text-sm text-gray-600 dark:text-gray-400 tabular-nums">
        {event.demand.toLocaleString()}
      </td>
      <td className="py-2.5 px-4 text-sm tabular-nums">
        <div className="flex items-center gap-2">
          <div className="w-24 h-1.5 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
            <div
              className="h-full bg-blue-500 rounded-full transition-all duration-300"
              style={{ width: `${pct}%` }}
            />
          </div>
          <span className="text-gray-600 dark:text-gray-400">{pct}%</span>
        </div>
      </td>
      <td className="py-2.5 px-4 text-sm text-gray-600 dark:text-gray-400 tabular-nums">
        {event.p95_ms}ms
      </td>
      <td className="py-2.5 px-4">
        <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${badge.classes}`}>
          {badge.label}
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
      <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-3">
        Multi-Event Flash Sales (Exp 4)
      </h2>
      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr>
              {HEADERS.map(h => (
                <th
                  key={h}
                  className="py-2 px-4 text-left text-xs font-semibold text-gray-400 dark:text-gray-500 uppercase tracking-wide"
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
