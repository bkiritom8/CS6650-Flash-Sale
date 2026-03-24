import React from 'react'

interface MetricCardProps {
  label: string
  value: string | number
  unit?: string
}

export function MetricCard({ label, value, unit }: MetricCardProps) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">
        {label}
      </span>
      <span className="text-3xl font-bold text-gray-900 dark:text-gray-100 tabular-nums">
        {value}
        {unit && (
          <span className="text-base font-normal text-gray-400 ml-1">{unit}</span>
        )}
      </span>
    </div>
  )
}
