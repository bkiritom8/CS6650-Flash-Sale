import { StrictMode } from 'react'
import ReactDOM from 'react-dom/client'
import './index.css'
import App from './App'
import { MetricsProvider } from './context/MetricsContext'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MetricsProvider>
      <App />
    </MetricsProvider>
  </StrictMode>,
)
