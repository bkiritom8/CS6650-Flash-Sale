import { useState } from 'react';

export function AdminLogin({ onLogin }: { onLogin: (password: string) => void }) {
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (password === 'admin') {
      onLogin(password);
    } else {
      setError('Incorrect password. Try "admin".');
    }
  };

  return (
    <div className="flex-center" style={{ minHeight: '60vh' }}>
      <form onSubmit={handleSubmit} className="glass-panel flex-col gap-6 animate-fade-in" style={{ padding: '32px', width: '100%', maxWidth: '400px', display: 'flex' }}>
        <div>
          <h2 className="text-xl font-bold text-gradient mb-2">Admin Access</h2>
          <p className="text-sm text-secondary">Enter password to access the backend views.</p>
        </div>

        {error && (
          <div className="status-badge mock" style={{ padding: '8px 12px', background: 'rgba(239, 68, 68, 0.1)', color: '#ef4444', borderColor: 'rgba(239, 68, 68, 0.2)' }}>
            {error}
          </div>
        )}

        <input
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="Password"
          className="select-base"
          style={{ width: '100%', padding: '12px', fontSize: '1rem' }}
          autoFocus
        />

        <button type="submit" className="btn-primary" style={{ width: '100%' }}>
          Unlock Backend
        </button>
      </form>
    </div>
  );
}
