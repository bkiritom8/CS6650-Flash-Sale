import React from 'react'
import ReactDOM from 'react-dom/client'
import './index.css'
import App from './App'
import { MetricsProvider } from './context/MetricsContext'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <MetricsProvider>
      <App />
    </MetricsProvider>
  </React.StrictMode>,
)
