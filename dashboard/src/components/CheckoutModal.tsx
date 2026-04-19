import { useSimulation } from '../context/SimulationContext'

export function CheckoutModal() {
  const { checkoutStatus, queuePosition, activeEvent, closeCheckout } = useSimulation()

  if (checkoutStatus === 'idle' || !activeEvent) return null

  return (
    <div className="modal-overlay">
      <div className="modal-content">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '24px' }}>
          <h2 className="title-xl" style={{ fontSize: '1.5rem', margin: 0 }}>
            {checkoutStatus === 'success' ? 'Got \'em!' : checkoutStatus === 'failed' ? 'Sold Out' : 'Securing Tickets'}
          </h2>
          {/* Allow closing if finished */}
          {(checkoutStatus === 'success' || checkoutStatus === 'failed') && (
            <button className="btn-secondary" onClick={closeCheckout}>Close</button>
          )}
        </div>

        <div style={{ display: 'flex', gap: '16px', marginBottom: '24px' }}>
          <img src={activeEvent.imageUrl} alt={activeEvent.name} style={{ width: '80px', height: '80px', borderRadius: '12px', objectFit: 'cover' }} />
          <div>
            <div style={{ fontWeight: 600, fontSize: '1.125rem' }}>{activeEvent.name}</div>
            <div style={{ color: 'var(--color-text-secondary)', fontSize: '0.875rem', marginTop: '4px' }}>{activeEvent.location} • {activeEvent.date}</div>
            <div style={{ color: 'var(--color-accent-primary)', fontWeight: 600, marginTop: '8px' }}>${activeEvent.price}</div>
          </div>
        </div>

        {checkoutStatus === 'in-queue' && (
          <div className="glass-panel" style={{ padding: '20px', background: 'rgba(255,255,255,0.03)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '0.875rem', color: 'var(--color-text-secondary)' }}>
              <span>Status</span>
              <span style={{ color: 'var(--color-text-primary)', fontWeight: 500 }}>In Queue</span>
            </div>
            <div className="progress-rail">
              <div className="progress-fill" style={{ width: `${Math.max(5, 100 - (queuePosition / 600) * 100)}%` }} />
            </div>
            <div style={{ textAlign: 'center', fontSize: '2rem', fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>
              {queuePosition.toLocaleString()}
            </div>
            <div style={{ textAlign: 'center', fontSize: '0.875rem', color: 'var(--color-text-secondary)' }}>
              people ahead of you
            </div>
          </div>
        )}

        {checkoutStatus === 'acquiring-lock' && (
          <div className="glass-panel" style={{ padding: '32px 20px', textAlign: 'center', background: 'rgba(255,255,255,0.03)' }}>
            <div className="live-indicator" style={{ width: '16px', height: '16px', margin: '0 auto 16px' }} />
            <div style={{ fontWeight: 600 }}>Acquiring Inventory Lock...</div>
            <div style={{ fontSize: '0.875rem', color: 'var(--color-text-secondary)', marginTop: '8px' }}>
              Please do not refresh this page.
            </div>
          </div>
        )}

        {checkoutStatus === 'success' && (
          <div className="glass-panel" style={{ padding: '24px', background: 'rgba(16, 185, 129, 0.1)', borderColor: 'rgba(16, 185, 129, 0.2)', textAlign: 'center' }}>
            <div style={{ color: '#10b981', fontSize: '3rem', marginBottom: '16px' }}>✓</div>
            <div style={{ fontWeight: 600, color: '#10b981', fontSize: '1.25rem' }}>Tickets Secured!</div>
            <div style={{ fontSize: '0.875rem', color: 'var(--color-text-secondary)', marginTop: '8px' }}>
              Your order for {activeEvent.name} is confirmed.
            </div>
          </div>
        )}

        {checkoutStatus === 'failed' && (
          <div className="glass-panel" style={{ padding: '24px', background: 'rgba(239, 68, 68, 0.1)', borderColor: 'rgba(239, 68, 68, 0.2)', textAlign: 'center' }}>
            <div style={{ color: '#ef4444', fontSize: '3rem', marginBottom: '16px' }}>✗</div>
            <div style={{ fontWeight: 600, color: '#ef4444', fontSize: '1.25rem' }}>Checkout Failed</div>
            <div style={{ fontSize: '0.875rem', color: 'var(--color-text-secondary)', marginTop: '8px' }}>
              We're sorry, the tickets you selected were purchased by another fan.
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
