import { TopBar } from './components/TopBar'
import { MetricCards } from './components/MetricCards'
import { ResponseTimeChart } from './components/ResponseTimeChart'
import { LockingComparisonPanel } from './components/LockingComparisonPanel'
import { MultiEventTable } from './components/MultiEventTable'
import { FairnessPanel } from './components/FairnessPanel'

export default function App() {
  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-bg)' }}>
      <TopBar />
      <main className="max-w-screen-xl mx-auto px-4 py-6 flex flex-col gap-4">

        {/* Row 1: 4 metric cards — full width */}
        <MetricCards />

        {/* Row 2: response time chart (2/3) + locking comparison (1/3) */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div className="lg:col-span-2">
            <ResponseTimeChart />
          </div>
          <div className="lg:col-span-1">
            <LockingComparisonPanel />
          </div>
        </div>

        {/* Row 3: multi-event table (2/3) + fairness panel (1/3) */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div className="lg:col-span-2">
            <MultiEventTable />
          </div>
          <div className="lg:col-span-1">
            <FairnessPanel />
          </div>
        </div>

      </main>
    </div>
  )
}
