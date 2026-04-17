import { useState } from 'react'
import { TopBar } from './components/TopBar'
import { MetricCards } from './components/MetricCards'
import { ResponseTimeChart } from './components/ResponseTimeChart'
import { LockingComparisonPanel } from './components/LockingComparisonPanel'
import { MultiEventTable } from './components/MultiEventTable'
import { FairnessPanel } from './components/FairnessPanel'
import { ExperimentsPanel } from './components/ExperimentsPanel'
import { EventList } from './components/EventList'
import { CheckoutModal } from './components/CheckoutModal'
import { AdminLogin } from './components/AdminLogin'

export type ViewState = 'analytics' | 'experiments' | 'user';

export default function App() {
  const [currentView, setCurrentView] = useState<ViewState>('user')
  const [isAdmin, setIsAdmin] = useState(false)

  const handleLogin = (password: string) => {
    if (password === 'admin') {
      setIsAdmin(true)
    }
  }

  const renderBackendView = (view: ViewState) => {
    if (!isAdmin) {
      return <AdminLogin onLogin={handleLogin} />
    }
    
    if (view === 'analytics') {
      return (
        <div className="animate-fade-in flex flex-col gap-6" style={{ display: 'flex', flexDirection: 'column', gap: '24px' }}>
          <MetricCards />
          <div className="grid-cols-3">
            <div className="col-span-2">
              <ResponseTimeChart />
            </div>
            <div className="col-span-1">
              <LockingComparisonPanel />
            </div>
          </div>
          <div className="grid-cols-3">
            <div className="col-span-2">
              <MultiEventTable />
            </div>
            <div className="col-span-1">
              <FairnessPanel />
            </div>
          </div>
        </div>
      )
    }

    if (view === 'experiments') {
      return <ExperimentsPanel />
    }

    return null
  }

  return (
    <div>
      <TopBar currentView={currentView} onViewChange={setCurrentView} isAdmin={isAdmin} />
      
      <main className={currentView === 'user' ? 'container' : 'dashboard-container'}>
        
        {(currentView === 'analytics' || currentView === 'experiments') && renderBackendView(currentView)}

        {currentView === 'user' && (
          <div className="animate-fade-in">
            <EventList />
            <CheckoutModal />
          </div>
        )}

      </main>
    </div>
  )
}
