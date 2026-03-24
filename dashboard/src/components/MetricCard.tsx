interface MetricCardProps {
  label: string
  value: string | number
  unit?: string
}

export function MetricCard({ label, value, unit }: MetricCardProps) {
  return (
    <div className="metric-card-content animate-fade-in glass-panel">
      <span className="metric-label">{label}</span>
      <span className="metric-value">
        {value}
        {unit && <span className="metric-unit">{unit}</span>}
      </span>
    </div>
  )
}
