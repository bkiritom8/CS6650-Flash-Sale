import { useSimulation } from '../context/SimulationContext'
import type { TicketEvent } from '../types'

function EventCard({ event }: { event: TicketEvent }) {
  const { initiateCheckout } = useSimulation()

  const isLive = event.status === 'live'

  return (
    <div className="glass-panel" style={{ display: 'flex', flexDirection: 'column' }}>
      <div style={{ position: 'relative', height: '180px', width: '100%', overflow: 'hidden' }}>
        <img 
          src={event.imageUrl} 
          alt={event.name} 
          style={{ width: '100%', height: '100%', objectFit: 'cover', transition: 'transform 0.5s ease' }} 
        />
        <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(to top, rgba(0,0,0,0.8), transparent)' }} />
        <div style={{ position: 'absolute', top: '16px', right: '16px' }}>
          {isLive ? (
            <span className="badge badge-live">
              <span className="live-indicator" />
              Sale Live
            </span>
          ) : event.status === 'upcoming' ? (
            <span className="badge badge-upcoming">Upcoming</span>
          ) : (
            <span className="badge badge-upcoming" style={{ color: '#ef4444', borderColor: 'rgba(239, 68, 68, 0.2)', background: 'rgba(239, 68, 68, 0.1)' }}>Sold Out</span>
          )}
        </div>
        <div style={{ position: 'absolute', bottom: '16px', left: '16px', right: '16px' }}>
          <h3 style={{ margin: 0, fontSize: '1.25rem', fontWeight: 700 }}>{event.name}</h3>
          <div style={{ fontSize: '0.875rem', color: 'rgba(255,255,255,0.8)', marginTop: '4px' }}>{event.location} • {event.date}</div>
        </div>
      </div>
      
      <div style={{ padding: '24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 'auto' }}>
        <div style={{ fontSize: '1.25rem', fontWeight: 700, color: 'var(--color-accent-primary)' }}>
          ${event.price}
        </div>
        <button 
          className="btn-primary" 
          disabled={!isLive}
          onClick={() => initiateCheckout(event)}
        >
          {isLive ? 'Join Queue' : 'Not Started'}
        </button>
      </div>
    </div>
  )
}

export function EventList() {
  const { events } = useSimulation()

  return (
    <section>
      <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
        <div>
          <h2 className="title-xl" style={{ fontSize: '2rem' }}>Featured Tours</h2>
          <p className="subtitle" style={{ margin: 0, fontSize: '1rem' }}>
            Get access to the most highly anticipated tours of the year.
          </p>
        </div>
      </div>
      
      <div className="grid-events">
        {events.map(ev => (
          <EventCard key={ev.id} event={ev} />
        ))}
      </div>
    </section>
  )
}
