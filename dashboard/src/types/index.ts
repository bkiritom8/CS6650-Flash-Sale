export interface TicketEvent {
  id: string
  name: string
  date: string
  location: string
  status: 'upcoming' | 'live' | 'sold-out'
  price: number
  imageUrl: string
}

export type CheckoutStatus = 'idle' | 'in-queue' | 'acquiring-lock' | 'success' | 'failed'

export interface SimulationState {
  events: TicketEvent[]
  queuePosition: number
  checkoutStatus: CheckoutStatus
  currentEvent: TicketEvent | null
}
