import { createContext, useContext, useState, type ReactNode, useCallback } from 'react'
import type { TicketEvent, CheckoutStatus } from '../types'

interface SimulationContextValue {
  events: TicketEvent[]
  checkoutStatus: CheckoutStatus
  queuePosition: number
  activeEvent: TicketEvent | null
  initiateCheckout: (event: TicketEvent) => void
  closeCheckout: () => void
}

const MOCK_EVENTS: TicketEvent[] = [
  { id: '1', name: 'Taylor Swift NYC', date: 'Oct 24, 2026', location: 'MetLife Stadium', status: 'live', price: 299, imageUrl: 'https://images.unsplash.com/photo-1540039155732-d6749b93223e?auto=format&fit=crop&q=80&w=800' },
  { id: '2', name: 'Bad Bunny LA', date: 'Nov 12, 2026', location: 'SoFi Stadium', status: 'live', price: 185, imageUrl: 'https://images.unsplash.com/photo-1459749411175-04bf5292ceea?auto=format&fit=crop&q=80&w=800' },
  { id: '3', name: 'Beyoncé Chicago', date: 'Dec 05, 2026', location: 'Soldier Field', status: 'upcoming', price: 350, imageUrl: 'https://images.unsplash.com/photo-1470229722913-7c090bd5a25b?auto=format&fit=crop&q=80&w=800' },
  { id: '4', name: 'Coldplay London', date: 'Jan 15, 2027', location: 'Wembley', status: 'upcoming', price: 120, imageUrl: 'https://images.unsplash.com/photo-1493225457124-a1a2a5ea3a72?auto=format&fit=crop&q=80&w=800' }
]

const SimulationContext = createContext<SimulationContextValue | null>(null)

export function SimulationProvider({ children }: { children: ReactNode }) {
  const [events] = useState<TicketEvent[]>(MOCK_EVENTS)
  const [checkoutStatus, setCheckoutStatus] = useState<CheckoutStatus>('idle')
  const [queuePosition, setQueuePosition] = useState(0)
  const [activeEvent, setActiveEvent] = useState<TicketEvent | null>(null)

  const closeCheckout = useCallback(() => {
    setCheckoutStatus('idle')
    setActiveEvent(null)
    setQueuePosition(0)
  }, [])

  const initiateCheckout = useCallback((event: TicketEvent) => {
    setActiveEvent(event)
    setCheckoutStatus('in-queue')
    
    // Simulate being placed in a massive queue
    let currentPos = Math.floor(Math.random() * 500) + 100
    setQueuePosition(currentPos)

    const timer = setInterval(() => {
      currentPos -= Math.floor(Math.random() * 40) + 10
      if (currentPos <= 0) {
        clearInterval(timer)
        setQueuePosition(0)
        setCheckoutStatus('acquiring-lock')
        
        // Simulate database locking contention
        setTimeout(() => {
          // 80% chance of success
          const success = Math.random() > 0.2
          setCheckoutStatus(success ? 'success' : 'failed')
        }, 1500)
      } else {
        setQueuePosition(currentPos)
      }
    }, 800)

  }, [])

  return (
    <SimulationContext.Provider value={{ events, checkoutStatus, queuePosition, activeEvent, initiateCheckout, closeCheckout }}>
      {children}
    </SimulationContext.Provider>
  )
}

export function useSimulation() {
  const ctx = useContext(SimulationContext)
  if (!ctx) throw new Error('useSimulation must be used within SimulationProvider')
  return ctx
}
