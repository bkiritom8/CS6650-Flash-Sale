import { EventList } from './components/EventList'
import { CheckoutModal } from './components/CheckoutModal'
import { SimulationProvider } from './context/SimulationContext'

function TopBar() {
  return (
    <header className="nav-header">
      <div className="nav-logo">
        <div className="nav-logo-icon" />
        <span className="text-gradient">AccelerateTicks</span>
      </div>
      
      <div style={{ display: 'flex', gap: '16px', alignItems: 'center' }}>
        <button className="btn-secondary">Fan Profile</button>
      </div>
    </header>
  )
}

function MainLayout() {
  return (
    <div className="container">
      <TopBar />
      <main>
        <EventList />
      </main>
      <CheckoutModal />
    </div>
  )
}

export default function App() {
  return (
    <SimulationProvider>
      <MainLayout />
    </SimulationProvider>
  )
}
