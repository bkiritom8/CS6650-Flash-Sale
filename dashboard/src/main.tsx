import { StrictMode } from 'react'
import ReactDOM from 'react-dom/client'
import './index.css'
import './user-view.css'
import App from './App'
import { MetricsProvider } from './context/MetricsContext'
import { SimulationProvider } from './context/SimulationContext'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MetricsProvider>
      <SimulationProvider>
        <App />
      </SimulationProvider>
    </MetricsProvider>
  </StrictMode>,
)
