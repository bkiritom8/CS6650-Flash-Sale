# Monitoring Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a real-time React/TypeScript monitoring dashboard for a concert ticket booking platform with WebSocket live data, Chart.js visualizations, mock fallback mode, and per-experiment panel highlighting.

**Architecture:** Vite + React 18 + TypeScript app in `dashboard/` directory. A `useWebSocket` hook manages the WS connection to `ws://localhost:8080/ws/metrics` and falls back to a stateful mock generator when the backend is unavailable. A `MetricsContext` provides global metrics state and experiment selection to all panels. Each panel is wrapped in a `PanelWrapper` that dims/highlights based on the active experiment.

**Tech Stack:** React 18, TypeScript, Vite, Tailwind CSS v3, Chart.js 4, react-chartjs-2, Vitest, @testing-library/react

---

## File Map

| File | Responsibility |
|------|----------------|
| `dashboard/src/types/metrics.ts` | All TypeScript interfaces for WS payload + experiment panel map |
| `dashboard/src/utils/mockGenerator.ts` | Stateful mock data generator with realistic drift/spikes |
| `dashboard/src/utils/mockGenerator.test.ts` | Unit tests for mock generator |
| `dashboard/src/hooks/useWebSocket.ts` | WS connection + LIVE/MOCK fallback + auto-reconnect |
| `dashboard/src/hooks/useWebSocket.test.ts` | Unit tests for WebSocket hook |
| `dashboard/src/context/MetricsContext.tsx` | Global metrics state + experiment selector |
| `dashboard/src/components/PanelWrapper.tsx` | Dim/highlight wrapper per active experiment |
| `dashboard/src/components/TopBar.tsx` | LIVE/MOCK badge + experiment dropdown + dark mode toggle |
| `dashboard/src/components/MetricCard.tsx` | Single KPI card |
| `dashboard/src/components/MetricCards.tsx` | Grid of 4 MetricCard instances |
| `dashboard/src/components/ResponseTimeChart.tsx` | Rolling 60s line chart with 3 datasets + custom HTML legend |
| `dashboard/src/components/LockingComparisonPanel.tsx` | Two horizontal bar charts (oversells + p95) |
| `dashboard/src/components/MultiEventTable.tsx` | Experiment 4 table with status badges |
| `dashboard/src/components/FairnessPanel.tsx` | Experiment 5 stacked progress bars + policy toggle |
| `dashboard/src/App.tsx` | Root layout — responsive grid assembling all panels |
| `dashboard/src/main.tsx` | React entry point, wraps App in MetricsProvider |
| `dashboard/src/index.css` | Tailwind directives + CSS custom properties for theming |
| `dashboard/src/test/setup.ts` | Vitest + jest-dom setup |

---

### Task 1: Scaffold Vite project

**Files:**
- Create: `dashboard/` (entire Vite scaffold)

- [ ] **Step 1: Scaffold Vite project**

```bash
cd /Users/bhargav/Documents/CS6650-BDS/CS6650-Flash-Sale
npm create vite@latest dashboard -- --template react-ts
cd dashboard
```

- [ ] **Step 2: Install runtime and dev dependencies**

```bash
npm install
npm install chart.js react-chartjs-2
npm install -D tailwindcss postcss autoprefixer
npm install -D vitest @vitest/ui @testing-library/react @testing-library/jest-dom @testing-library/user-event jsdom
npx tailwindcss init -p
```

- [ ] **Step 3: Configure Tailwind** — `npx tailwindcss init -p` generates `tailwind.config.js` by default. Rename it to `.ts` first (`mv dashboard/tailwind.config.js dashboard/tailwind.config.ts`), then replace its contents:

```typescript
import type { Config } from 'tailwindcss'

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: { extend: {} },
  plugins: [],
} satisfies Config
```

- [ ] **Step 4: Configure Vite with Vitest** — replace `dashboard/vite.config.ts`:

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: './src/test/setup.ts',
  },
})
```

- [ ] **Step 5: Create test setup file** — `dashboard/src/test/setup.ts`:

```typescript
import '@testing-library/jest-dom'
```

- [ ] **Step 6: Add test scripts to package.json**

Ensure `dashboard/package.json` scripts block includes:
```json
"test": "vitest run",
"test:watch": "vitest"
```

- [ ] **Step 7: Write `dashboard/src/index.css`** (replace existing):

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

:root {
  --color-bg: #f9fafb;
  --color-panel: #ffffff;
  --color-border: #e5e7eb;
  --color-text-primary: #111827;
  --color-text-secondary: #6b7280;
  --color-grid: #f3f4f6;
  --color-chart-no-lock: #ef4444;
  --color-chart-optimistic: #3b82f6;
  --color-chart-pessimistic: #9ca3af;
}

.dark {
  --color-bg: #111827;
  --color-panel: #1f2937;
  --color-border: #374151;
  --color-text-primary: #f9fafb;
  --color-text-secondary: #9ca3af;
  --color-grid: #374151;
}

body {
  background-color: var(--color-bg);
  color: var(--color-text-primary);
}
```

- [ ] **Step 8: Verify dev server starts**

```bash
cd dashboard && npm run dev
```
Expected: Vite server running at http://localhost:5173 with no errors.

- [ ] **Step 9: Commit**

```bash
cd /Users/bhargav/Documents/CS6650-BDS/CS6650-Flash-Sale
git add dashboard/
git commit -m "feat: scaffold Vite React TypeScript dashboard project"
```

---

### Task 2: TypeScript types

**Files:**
- Create: `dashboard/src/types/metrics.ts`

- [ ] **Step 1: Write the types file**

```typescript
// dashboard/src/types/metrics.ts

export interface ResponseTimes {
  no_lock: number[];
  optimistic: number[];
  pessimistic: number[];
}

export interface LockingStrategyData {
  oversells: number;
  p95_ms: number;
}

export interface LockingComparison {
  no_lock: LockingStrategyData;
  optimistic: LockingStrategyData;
  pessimistic: LockingStrategyData;
}

export interface EventData {
  name: string;
  demand: number;
  success_rate: number;
  p95_ms: number;
}

export interface FairnessPolicyData {
  single_avg_position: number;
  multi_avg_position: number;
}

export interface FairnessData {
  single_tab_pct: number;
  multi_tab_pct: number;
  collapse_policy: FairnessPolicyData;
  allow_policy: FairnessPolicyData;
}

export interface MetricsPayload {
  queue_depth: number;
  bookings_per_sec: number;
  oversell_count: number;
  ecs_tasks: number;
  response_times: ResponseTimes;
  locking_comparison: LockingComparison;
  events: EventData[];
  fairness: FairnessData;
}

export type ConnectionStatus = 'live' | 'mock';

export type PolicyToggle = 'collapse' | 'allow';

export type ExperimentId = 1 | 2 | 3 | 4 | 5;

/** Defines which panel IDs are highlighted for each experiment */
export const EXPERIMENT_PANELS: Record<ExperimentId, string[]> = {
  1: ['metric-cards', 'response-time-chart'],
  2: ['response-time-chart', 'locking-comparison'],
  3: ['response-time-chart', 'locking-comparison'],
  4: ['metric-cards', 'multi-event-table'],
  5: ['fairness-panel'],
};
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/types/
git commit -m "feat: add TypeScript interfaces for metrics WebSocket payload"
```

---

### Task 3: Mock data generator

**Files:**
- Create: `dashboard/src/utils/mockGenerator.ts`
- Test: `dashboard/src/utils/mockGenerator.test.ts`

- [ ] **Step 1: Write failing tests** — `dashboard/src/utils/mockGenerator.test.ts`:

```typescript
import { describe, it, expect } from 'vitest'
import { createMockGenerator } from './mockGenerator'

describe('createMockGenerator', () => {
  it('returns a payload with all required keys', () => {
    const gen = createMockGenerator()
    const payload = gen.next()
    expect(payload).toHaveProperty('queue_depth')
    expect(payload).toHaveProperty('bookings_per_sec')
    expect(payload).toHaveProperty('oversell_count')
    expect(payload).toHaveProperty('ecs_tasks')
    expect(payload).toHaveProperty('response_times')
    expect(payload).toHaveProperty('locking_comparison')
    expect(payload).toHaveProperty('events')
    expect(payload).toHaveProperty('fairness')
  })

  it('queue_depth stays within realistic bounds over 100 ticks', () => {
    const gen = createMockGenerator()
    for (let i = 0; i < 100; i++) {
      const p = gen.next()
      expect(p.queue_depth).toBeGreaterThanOrEqual(0)
      expect(p.queue_depth).toBeLessThanOrEqual(2000)
    }
  })

  it('ecs_tasks stays within 1–20', () => {
    const gen = createMockGenerator()
    for (let i = 0; i < 50; i++) {
      const p = gen.next()
      expect(p.ecs_tasks).toBeGreaterThanOrEqual(1)
      expect(p.ecs_tasks).toBeLessThanOrEqual(20)
    }
  })

  it('response_times arrays have exactly 20 elements', () => {
    const gen = createMockGenerator()
    const p = gen.next()
    expect(p.response_times.no_lock).toHaveLength(20)
    expect(p.response_times.optimistic).toHaveLength(20)
    expect(p.response_times.pessimistic).toHaveLength(20)
  })

  it('fairness percentages sum to 1.0', () => {
    const gen = createMockGenerator()
    const p = gen.next()
    expect(p.fairness.single_tab_pct + p.fairness.multi_tab_pct).toBeCloseTo(1.0, 2)
  })

  it('event success_rate is in [0, 1]', () => {
    const gen = createMockGenerator()
    const p = gen.next()
    expect(p.events.length).toBeGreaterThan(0)
    p.events.forEach(e => {
      expect(e.success_rate).toBeGreaterThanOrEqual(0)
      expect(e.success_rate).toBeLessThanOrEqual(1)
    })
  })
})
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd dashboard && npx vitest run src/utils/mockGenerator.test.ts
```
Expected: FAIL — `Cannot find module './mockGenerator'`

- [ ] **Step 3: Implement mock generator** — `dashboard/src/utils/mockGenerator.ts`:

```typescript
import type { MetricsPayload } from '../types/metrics'

function clamp(val: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, val))
}

function drift(current: number, target: number, speed: number, noise: number): number {
  return current + (target - current) * speed + (Math.random() - 0.5) * noise
}

function rand(min: number, max: number): number {
  return min + Math.random() * (max - min)
}

const EVENTS = [
  { name: 'Taylor Swift NYC',    baseDemand: 1000, baseRate: 0.78 },
  { name: 'Bad Bunny LA',        baseDemand: 850,  baseRate: 0.85 },
  { name: 'Beyoncé Chicago',     baseDemand: 1200, baseRate: 0.62 },
  { name: 'Coldplay Boston',     baseDemand: 600,  baseRate: 0.92 },
  { name: 'Kendrick Lamar SF',   baseDemand: 950,  baseRate: 0.71 },
]

export interface MockGenerator {
  next: () => MetricsPayload
}

export function createMockGenerator(): MockGenerator {
  let queueDepth = 500
  let queueTarget = 600
  let oversellCount = 0
  let singleTabPct = 0.63
  let tick = 0

  const rtHistory = {
    no_lock:     Array.from({ length: 20 }, () => rand(40, 55)),
    optimistic:  Array.from({ length: 20 }, () => rand(78, 95)),
    pessimistic: Array.from({ length: 20 }, () => rand(148, 170)),
  }

  return {
    next(): MetricsPayload {
      tick++

      // Simulate periodic demand spikes
      if (tick % 30 === 0)  queueTarget = rand(800, 1600)
      if (tick % 30 === 15) queueTarget = rand(200, 500)

      queueDepth = clamp(drift(queueDepth, queueTarget, 0.1, 40), 0, 2000)
      const bookingsPerSec = Math.round(clamp(rand(20, 60) + queueDepth * 0.02, 0, 120))
      const ecsTasks = clamp(Math.ceil(queueDepth / 200) + Math.round(rand(-1, 1)), 1, 20)

      if (Math.random() < 0.15) oversellCount++

      // Roll response time history windows
      rtHistory.no_lock.push(clamp(rand(40, 55) + queueDepth * 0.005, 30, 200))
      rtHistory.no_lock.shift()
      rtHistory.optimistic.push(clamp(rand(78, 95) + queueDepth * 0.01, 60, 300))
      rtHistory.optimistic.shift()
      rtHistory.pessimistic.push(clamp(rand(148, 170) + queueDepth * 0.015, 120, 500))
      rtHistory.pessimistic.shift()

      singleTabPct = clamp(drift(singleTabPct, 0.63, 0.02, 0.02), 0.45, 0.80)
      const multiTabPct = parseFloat((1 - singleTabPct).toFixed(2))

      const events = EVENTS.map(e => ({
        name: e.name,
        demand: Math.round(e.baseDemand + rand(-50, 50)),
        success_rate: parseFloat(clamp(e.baseRate + rand(-0.05, 0.05), 0, 1).toFixed(3)),
        p95_ms: Math.round(rand(100, 200)),
      }))

      return {
        queue_depth: Math.round(queueDepth),
        bookings_per_sec: bookingsPerSec,
        oversell_count: oversellCount,
        ecs_tasks: ecsTasks,
        response_times: {
          no_lock:     [...rtHistory.no_lock],
          optimistic:  [...rtHistory.optimistic],
          pessimistic: [...rtHistory.pessimistic],
        },
        locking_comparison: {
          no_lock:     { oversells: oversellCount,                          p95_ms: Math.round(rand(44, 52))  },
          optimistic:  { oversells: Math.round(oversellCount * 0.08),       p95_ms: Math.round(rand(82, 96))  },
          pessimistic: { oversells: 0,                                       p95_ms: Math.round(rand(152, 168)) },
        },
        events,
        fairness: {
          single_tab_pct: parseFloat(singleTabPct.toFixed(2)),
          multi_tab_pct:  multiTabPct,
          collapse_policy: {
            single_avg_position: Math.round(rand(340, 370)),
            multi_avg_position:  Math.round(rand(350, 375)),
          },
          allow_policy: {
            single_avg_position: Math.round(rand(400, 425)),
            multi_avg_position:  Math.round(rand(185, 215)),
          },
        },
      }
    },
  }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd dashboard && npx vitest run src/utils/mockGenerator.test.ts
```
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/utils/
git commit -m "feat: add mock data generator with realistic drift and spike simulation"
```

---

### Task 4: useWebSocket hook

**Files:**
- Create: `dashboard/src/hooks/useWebSocket.ts`
- Test: `dashboard/src/hooks/useWebSocket.test.ts`

- [ ] **Step 1: Write failing tests** — `dashboard/src/hooks/useWebSocket.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useWebSocket } from './useWebSocket'

class MockWebSocket {
  static OPEN = 1
  readyState = MockWebSocket.OPEN
  onopen: (() => void) | null = null
  onmessage: ((e: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  close = vi.fn()
  constructor(public url: string) {
    // Fire onopen asynchronously to simulate real WS
    setTimeout(() => this.onopen?.(), 0)
  }
}

describe('useWebSocket', () => {
  beforeEach(() => { vi.stubGlobal('WebSocket', MockWebSocket) })
  afterEach(() => { vi.unstubAllGlobals() })

  it('starts with mock metrics before WS opens', () => {
    const { result } = renderHook(() => useWebSocket('ws://localhost:8080/ws/metrics'))
    expect(result.current.status).toBe('mock')
    expect(result.current.metrics).not.toBeNull()
  })

  it('switches to live status when WebSocket opens', async () => {
    const { result } = renderHook(() => useWebSocket('ws://localhost:8080/ws/metrics'))
    await act(async () => { await new Promise(r => setTimeout(r, 10)) })
    expect(result.current.status).toBe('live')
  })

  it('updates metrics when a valid message arrives', async () => {
    let wsInstance: MockWebSocket | null = null
    vi.stubGlobal('WebSocket', class extends MockWebSocket {
      constructor(url: string) { super(url); wsInstance = this }
    })

    const { result } = renderHook(() => useWebSocket('ws://localhost:8080/ws/metrics'))
    await act(async () => { await new Promise(r => setTimeout(r, 10)) })

    act(() => {
      wsInstance!.onmessage?.({ data: JSON.stringify({ queue_depth: 999, bookings_per_sec: 42 }) })
    })

    expect(result.current.metrics?.queue_depth).toBe(999)
  })
})
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd dashboard && npx vitest run src/hooks/useWebSocket.test.ts
```
Expected: FAIL — `Cannot find module './useWebSocket'`

- [ ] **Step 3: Implement the hook** — `dashboard/src/hooks/useWebSocket.ts`:

```typescript
import { useState, useEffect, useRef, useCallback } from 'react'
import type { MetricsPayload, ConnectionStatus } from '../types/metrics'
import { createMockGenerator } from '../utils/mockGenerator'

export interface WebSocketState {
  metrics: MetricsPayload | null
  status: ConnectionStatus
}

export function useWebSocket(url: string): WebSocketState {
  const generator = useRef(createMockGenerator())
  const [metrics, setMetrics] = useState<MetricsPayload | null>(() => generator.current.next())
  const [status, setStatus] = useState<ConnectionStatus>('mock')
  const wsRef = useRef<WebSocket | null>(null)
  const mockIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const startMock = useCallback(() => {
    setStatus('mock')
    if (mockIntervalRef.current) clearInterval(mockIntervalRef.current)
    mockIntervalRef.current = setInterval(() => {
      setMetrics(generator.current.next())
    }, 2000)
  }, [])

  const stopMock = useCallback(() => {
    if (mockIntervalRef.current) {
      clearInterval(mockIntervalRef.current)
      mockIntervalRef.current = null
    }
  }, [])

  useEffect(() => {
    startMock()
    let reconnectTimer: ReturnType<typeof setTimeout>

    function connect() {
      try {
        const ws = new WebSocket(url)
        wsRef.current = ws

        ws.onopen = () => { setStatus('live'); stopMock() }

        ws.onmessage = (event: MessageEvent) => {
          try {
            setMetrics(JSON.parse(event.data) as MetricsPayload)
          } catch { /* ignore malformed */ }
        }

        ws.onclose = () => {
          startMock()
          reconnectTimer = setTimeout(connect, 5000)
        }

        ws.onerror = () => { ws.close() }
      } catch {
        startMock()
        reconnectTimer = setTimeout(connect, 5000)
      }
    }

    connect()

    return () => {
      clearTimeout(reconnectTimer)
      stopMock()
      wsRef.current?.close()
    }
  }, [url, startMock, stopMock])

  return { metrics, status }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd dashboard && npx vitest run src/hooks/useWebSocket.test.ts
```
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/hooks/
git commit -m "feat: add useWebSocket hook with LIVE/MOCK fallback and 5s auto-reconnect"
```

---

### Task 5: MetricsContext + main.tsx wiring

**Files:**
- Create: `dashboard/src/context/MetricsContext.tsx`
- Modify: `dashboard/src/main.tsx`

- [ ] **Step 1: Write context** — `dashboard/src/context/MetricsContext.tsx`:

```typescript
import React, { createContext, useContext, useState } from 'react'
import { useWebSocket } from '../hooks/useWebSocket'
import type { MetricsPayload, ConnectionStatus, ExperimentId } from '../types/metrics'

interface MetricsContextValue {
  metrics: MetricsPayload | null
  status: ConnectionStatus
  experiment: ExperimentId
  setExperiment: (id: ExperimentId) => void
}

const MetricsContext = createContext<MetricsContextValue | null>(null)

export function MetricsProvider({ children }: { children: React.ReactNode }) {
  const { metrics, status } = useWebSocket('ws://localhost:8080/ws/metrics')
  const [experiment, setExperiment] = useState<ExperimentId>(1)

  return (
    <MetricsContext.Provider value={{ metrics, status, experiment, setExperiment }}>
      {children}
    </MetricsContext.Provider>
  )
}

export function useMetrics(): MetricsContextValue {
  const ctx = useContext(MetricsContext)
  if (!ctx) throw new Error('useMetrics must be used inside MetricsProvider')
  return ctx
}
```

- [ ] **Step 2: Wire provider into main.tsx** — replace `dashboard/src/main.tsx`:

```typescript
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
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/context/ dashboard/src/main.tsx
git commit -m "feat: add MetricsContext with experiment selector and wire into app root"
```

---

### Task 6: PanelWrapper + TopBar

**Files:**
- Create: `dashboard/src/components/PanelWrapper.tsx`
- Create: `dashboard/src/components/TopBar.tsx`

- [ ] **Step 1: Write PanelWrapper** — `dashboard/src/components/PanelWrapper.tsx`:

```tsx
import React from 'react'
import { useMetrics } from '../context/MetricsContext'
import { EXPERIMENT_PANELS } from '../types/metrics'

interface PanelWrapperProps {
  panelId: string
  children: React.ReactNode
  className?: string
}

export function PanelWrapper({ panelId, children, className = '' }: PanelWrapperProps) {
  const { experiment } = useMetrics()
  const active = EXPERIMENT_PANELS[experiment].includes(panelId)

  return (
    <div
      className={`
        bg-white dark:bg-gray-800
        border border-gray-200 dark:border-gray-700
        rounded-xl p-5
        transition-opacity duration-300
        ${active ? 'opacity-100' : 'opacity-30'}
        ${className}
      `}
    >
      {children}
    </div>
  )
}
```

- [ ] **Step 2: Write TopBar** — `dashboard/src/components/TopBar.tsx`:

```tsx
import React, { useState } from 'react'
import { useMetrics } from '../context/MetricsContext'
import type { ExperimentId } from '../types/metrics'

const EXPERIMENTS: { id: ExperimentId; label: string }[] = [
  { id: 1, label: 'Exp 1 — No-lock Baseline' },
  { id: 2, label: 'Exp 2 — Optimistic Locking' },
  { id: 3, label: 'Exp 3 — Pessimistic Locking' },
  { id: 4, label: 'Exp 4 — Multi-Event' },
  { id: 5, label: 'Exp 5 — Fairness Distribution' },
]

export function TopBar() {
  const { status, experiment, setExperiment } = useMetrics()
  const [dark, setDark] = useState(false)

  function toggleDark() {
    const next = !dark
    setDark(next)
    document.documentElement.classList.toggle('dark', next)
  }

  return (
    <header className="sticky top-0 z-10 flex items-center justify-between px-6 py-3 bg-white dark:bg-gray-900 border-b border-gray-200 dark:border-gray-700">
      <div className="flex items-center gap-3">
        <h1 className="text-base font-semibold text-gray-900 dark:text-gray-100 tracking-tight">
          Flash Sale Monitor
        </h1>
        <span
          className={`inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium ${
            status === 'live'
              ? 'bg-green-100 text-green-700'
              : 'bg-amber-100 text-amber-700'
          }`}
        >
          <span
            className={`w-1.5 h-1.5 rounded-full ${
              status === 'live' ? 'bg-green-500 animate-pulse' : 'bg-amber-400'
            }`}
          />
          {status === 'live' ? 'LIVE' : 'MOCK'}
        </span>
      </div>

      <div className="flex items-center gap-3">
        <button
          onClick={toggleDark}
          className="text-xs text-gray-500 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-100 border border-gray-200 dark:border-gray-600 rounded px-2 py-1"
        >
          {dark ? '☀ Light' : '☾ Dark'}
        </button>

        <div className="flex items-center gap-2">
          <label htmlFor="exp-select" className="text-xs text-gray-500 dark:text-gray-400">
            Experiment:
          </label>
          <select
            id="exp-select"
            value={experiment}
            onChange={e => setExperiment(Number(e.target.value) as ExperimentId)}
            className="text-sm border border-gray-200 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200 rounded-md px-2 py-1 text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            {EXPERIMENTS.map(({ id, label }) => (
              <option key={id} value={id}>{label}</option>
            ))}
          </select>
        </div>
      </div>
    </header>
  )
}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/PanelWrapper.tsx dashboard/src/components/TopBar.tsx
git commit -m "feat: add PanelWrapper with dim/highlight and TopBar with LIVE/MOCK badge, dark toggle, experiment selector"
```

---

### Task 7: MetricCards panel

**Files:**
- Create: `dashboard/src/components/MetricCard.tsx`
- Create: `dashboard/src/components/MetricCards.tsx`

- [ ] **Step 1: Write MetricCard** — `dashboard/src/components/MetricCard.tsx`:

```tsx
import React from 'react'

interface MetricCardProps {
  label: string
  value: string | number
  unit?: string
}

export function MetricCard({ label, value, unit }: MetricCardProps) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">
        {label}
      </span>
      <span className="text-3xl font-bold text-gray-900 dark:text-gray-100 tabular-nums">
        {value}
        {unit && (
          <span className="text-base font-normal text-gray-400 ml-1">{unit}</span>
        )}
      </span>
    </div>
  )
}
```

- [ ] **Step 2: Write MetricCards** — `dashboard/src/components/MetricCards.tsx`:

```tsx
import React from 'react'
import { PanelWrapper } from './PanelWrapper'
import { MetricCard } from './MetricCard'
import { useMetrics } from '../context/MetricsContext'

export function MetricCards() {
  const { metrics } = useMetrics()
  if (!metrics) return null

  return (
    <PanelWrapper panelId="metric-cards">
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-6">
        <MetricCard label="Queue Depth" value={metrics.queue_depth.toLocaleString()} />
        <MetricCard label="Bookings / sec" value={metrics.bookings_per_sec} />
        <MetricCard label="Oversell Events" value={metrics.oversell_count} />
        <MetricCard label="ECS Tasks" value={metrics.ecs_tasks} />
      </div>
    </PanelWrapper>
  )
}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/MetricCard.tsx dashboard/src/components/MetricCards.tsx
git commit -m "feat: add MetricCards panel with four auto-updating KPI cards"
```

---

### Task 8: ResponseTimeChart

**Files:**
- Create: `dashboard/src/components/ResponseTimeChart.tsx`

- [ ] **Step 1: Write the chart component** — `dashboard/src/components/ResponseTimeChart.tsx`:

```tsx
import React, { useEffect, useRef } from 'react'
import {
  Chart,
  LineController,
  LineElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Tooltip,
} from 'chart.js'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'

Chart.register(LineController, LineElement, PointElement, LinearScale, CategoryScale, Tooltip)

// X-axis labels: 20 points spaced 3s apart, up to 0 (now)
const X_LABELS = Array.from({ length: 20 }, (_, i) => `${(19 - i) * -3}s`)

const SERIES = [
  { key: 'no_lock'     as const, label: 'No-lock baseline',   color: '#ef4444' },
  { key: 'optimistic'  as const, label: 'Optimistic locking',  color: '#3b82f6' },
  { key: 'pessimistic' as const, label: 'Pessimistic locking', color: '#9ca3af' },
]

function gridColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--color-grid').trim() || '#f3f4f6'
}

export function ResponseTimeChart() {
  const { metrics } = useMetrics()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const chartRef  = useRef<Chart | null>(null)

  useEffect(() => {
    if (!canvasRef.current) return
    const gc = gridColor()

    chartRef.current = new Chart(canvasRef.current, {
      type: 'line',
      data: {
        labels: X_LABELS,
        datasets: SERIES.map(({ label, color }) => ({
          label,
          data: Array(20).fill(null),
          borderColor: color,
          backgroundColor: 'transparent',
          borderWidth: 2,
          pointRadius: 0,
          tension: 0.3,
        })),
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: {
          legend: { display: false },
          tooltip: { mode: 'index', intersect: false },
        },
        scales: {
          x: {
            grid: { color: gc },
            ticks: { color: '#6b7280', font: { size: 11 } },
          },
          y: {
            grid: { color: gc },
            ticks: {
              color: '#6b7280',
              font: { size: 11 },
              callback: v => `${v}ms`,
            },
            beginAtZero: true,
          },
        },
      },
    })
    return () => chartRef.current?.destroy()
  }, [])

  useEffect(() => {
    if (!chartRef.current || !metrics) return
    const rt = metrics.response_times
    chartRef.current.data.datasets[0].data = rt.no_lock
    chartRef.current.data.datasets[1].data = rt.optimistic
    chartRef.current.data.datasets[2].data = rt.pessimistic
    chartRef.current.update('none')
  }, [metrics])

  return (
    <PanelWrapper panelId="response-time-chart">
      {/* Custom HTML legend */}
      <div className="mb-3">
        <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
          Response Time — rolling 60s window
        </h2>
        <div className="flex flex-wrap gap-4">
          {SERIES.map(({ label, color }) => (
            <div key={label} className="flex items-center gap-1.5">
              <span
                className="w-5 h-0.5 inline-block rounded"
                style={{ backgroundColor: color }}
              />
              <span className="text-xs text-gray-500 dark:text-gray-400">{label}</span>
            </div>
          ))}
        </div>
      </div>
      <div className="h-56">
        <canvas ref={canvasRef} />
      </div>
    </PanelWrapper>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/ResponseTimeChart.tsx
git commit -m "feat: add ResponseTimeChart with rolling 60s window, 3 datasets, custom HTML legend"
```

---

### Task 9: LockingComparisonPanel

**Files:**
- Create: `dashboard/src/components/LockingComparisonPanel.tsx`

- [ ] **Step 1: Write the panel** — `dashboard/src/components/LockingComparisonPanel.tsx`:

```tsx
import React, { useEffect, useRef } from 'react'
import {
  Chart,
  BarController,
  BarElement,
  LinearScale,
  CategoryScale,
  Tooltip,
} from 'chart.js'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'

Chart.register(BarController, BarElement, LinearScale, CategoryScale, Tooltip)

const STRATEGIES = ['No-lock', 'Optimistic', 'Pessimistic']
const COLORS      = ['#ef4444', '#3b82f6', '#9ca3af']

function gridColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--color-grid').trim() || '#f3f4f6'
}

interface HBarChartProps {
  canvasId: string
  title: string
  data: number[]
  unit: string
}

function HBarChart({ canvasId, title, data, unit }: HBarChartProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const chartRef  = useRef<Chart | null>(null)

  useEffect(() => {
    if (!canvasRef.current) return
    const gc = gridColor()

    chartRef.current = new Chart(canvasRef.current, {
      type: 'bar',
      data: {
        labels: STRATEGIES,
        datasets: [{
          data,
          backgroundColor: COLORS,
          borderRadius: 4,
          barThickness: 18,
        }],
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: { label: ctx => ` ${ctx.raw}${unit}` } },
        },
        scales: {
          x: {
            grid: { color: gc },
            ticks: { color: '#6b7280', font: { size: 11 }, callback: v => `${v}${unit}` },
          },
          y: {
            grid: { display: false },
            ticks: { color: '#374151', font: { size: 12 } },
          },
        },
      },
    })
    return () => chartRef.current?.destroy()
  }, [])

  useEffect(() => {
    if (!chartRef.current) return
    chartRef.current.data.datasets[0].data = data
    chartRef.current.update('none')
  }, [data])

  return (
    <div>
      <h3 className="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-2">
        {title}
      </h3>
      <div className="h-24">
        <canvas ref={canvasRef} id={canvasId} />
      </div>
    </div>
  )
}

export function LockingComparisonPanel() {
  const { metrics } = useMetrics()
  if (!metrics) return null

  const lc = metrics.locking_comparison
  const oversells = [lc.no_lock.oversells, lc.optimistic.oversells, lc.pessimistic.oversells]
  const p95       = [lc.no_lock.p95_ms,    lc.optimistic.p95_ms,    lc.pessimistic.p95_ms]

  return (
    <PanelWrapper panelId="locking-comparison">
      <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-4">
        Locking Strategy Comparison
      </h2>
      <div className="flex flex-col gap-5">
        <HBarChart canvasId="chart-oversells" title="Oversell Count"  data={oversells} unit=""   />
        <div className="border-t border-gray-100 dark:border-gray-700" />
        <HBarChart canvasId="chart-p95"       title="P95 Latency (ms)" data={p95}    unit="ms" />
      </div>
    </PanelWrapper>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/LockingComparisonPanel.tsx
git commit -m "feat: add LockingComparisonPanel with oversell count and p95 horizontal bar charts"
```

---

### Task 10: MultiEventTable

**Files:**
- Create: `dashboard/src/components/MultiEventTable.tsx`

- [ ] **Step 1: Write the component** — `dashboard/src/components/MultiEventTable.tsx`:

```tsx
import React from 'react'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'
import type { EventData } from '../types/metrics'

function statusBadge(rate: number): { label: string; classes: string } {
  if (rate > 0.90) return { label: 'Healthy',    classes: 'bg-green-100 text-green-700' }
  if (rate >= 0.75) return { label: 'Degraded',  classes: 'bg-amber-100 text-amber-700' }
  return               { label: 'Contention', classes: 'bg-red-100 text-red-700'   }
}

function EventRow({ event }: { event: EventData }) {
  const badge = statusBadge(event.success_rate)
  const pct   = (event.success_rate * 100).toFixed(1)

  return (
    <tr className="border-t border-gray-100 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-750 transition-colors">
      <td className="py-2.5 px-4 text-sm font-medium text-gray-800 dark:text-gray-200">
        {event.name}
      </td>
      <td className="py-2.5 px-4 text-sm text-gray-600 dark:text-gray-400 tabular-nums">
        {event.demand.toLocaleString()}
      </td>
      <td className="py-2.5 px-4 text-sm tabular-nums">
        <div className="flex items-center gap-2">
          <div className="w-24 h-1.5 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
            <div
              className="h-full bg-blue-500 rounded-full transition-all duration-300"
              style={{ width: `${pct}%` }}
            />
          </div>
          <span className="text-gray-600 dark:text-gray-400">{pct}%</span>
        </div>
      </td>
      <td className="py-2.5 px-4 text-sm text-gray-600 dark:text-gray-400 tabular-nums">
        {event.p95_ms}ms
      </td>
      <td className="py-2.5 px-4">
        <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${badge.classes}`}>
          {badge.label}
        </span>
      </td>
    </tr>
  )
}

const HEADERS = ['Event', 'Demand', 'Success Rate', 'P95', 'Status']

export function MultiEventTable() {
  const { metrics } = useMetrics()
  if (!metrics) return null

  return (
    <PanelWrapper panelId="multi-event-table">
      <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-3">
        Multi-Event Flash Sales (Exp 4)
      </h2>
      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr>
              {HEADERS.map(h => (
                <th
                  key={h}
                  className="py-2 px-4 text-left text-xs font-semibold text-gray-400 dark:text-gray-500 uppercase tracking-wide"
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {metrics.events.map(event => (
              <EventRow key={event.name} event={event} />
            ))}
          </tbody>
        </table>
      </div>
    </PanelWrapper>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/MultiEventTable.tsx
git commit -m "feat: add MultiEventTable with status badges and inline success-rate progress bars"
```

---

### Task 11: FairnessPanel

**Files:**
- Create: `dashboard/src/components/FairnessPanel.tsx`

- [ ] **Step 1: Write the component** — `dashboard/src/components/FairnessPanel.tsx`:

```tsx
import React, { useState } from 'react'
import { PanelWrapper } from './PanelWrapper'
import { useMetrics } from '../context/MetricsContext'
import type { PolicyToggle } from '../types/metrics'

function StackedBar({ singlePct, multiPct }: { singlePct: number; multiPct: number }) {
  return (
    <div>
      <div className="flex text-xs text-gray-500 dark:text-gray-400 justify-between mb-1">
        <span>Single-tab ({(singlePct * 100).toFixed(0)}%)</span>
        <span>Multi-tab ({(multiPct * 100).toFixed(0)}%)</span>
      </div>
      <div className="flex h-4 rounded-full overflow-hidden">
        <div
          className="bg-blue-500 transition-all duration-500"
          style={{ width: `${singlePct * 100}%` }}
        />
        <div
          className="bg-amber-400 transition-all duration-500"
          style={{ width: `${multiPct * 100}%` }}
        />
      </div>
    </div>
  )
}

export function FairnessPanel() {
  const { metrics } = useMetrics()
  const [policy, setPolicy] = useState<PolicyToggle>('collapse')
  if (!metrics) return null

  const f          = metrics.fairness
  const policyData = policy === 'collapse' ? f.collapse_policy : f.allow_policy

  return (
    <PanelWrapper panelId="fairness-panel">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-sm font-semibold text-gray-700 dark:text-gray-300">
          Fairness Distribution (Exp 5)
        </h2>
        {/* Policy toggle */}
        <div className="flex rounded-lg border border-gray-200 dark:border-gray-600 overflow-hidden text-xs">
          {(['collapse', 'allow'] as PolicyToggle[]).map(p => (
            <button
              key={p}
              onClick={() => setPolicy(p)}
              className={`px-3 py-1.5 font-medium transition-colors ${
                policy === p
                  ? 'bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900'
                  : 'bg-white dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
              }`}
            >
              {p === 'collapse' ? 'Collapse by IP' : 'Allow Multiple'}
            </button>
          ))}
        </div>
      </div>

      <div className="flex flex-col gap-5">
        <StackedBar singlePct={f.single_tab_pct} multiPct={f.multi_tab_pct} />

        <div className="grid grid-cols-2 gap-3">
          <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-3">
            <div className="text-xs text-blue-600 dark:text-blue-400 font-medium mb-1">
              Single-tab avg position
            </div>
            <div className="text-2xl font-bold text-blue-700 dark:text-blue-300 tabular-nums">
              #{policyData.single_avg_position.toLocaleString()}
            </div>
          </div>
          <div className="bg-amber-50 dark:bg-amber-900/20 rounded-lg p-3">
            <div className="text-xs text-amber-600 dark:text-amber-400 font-medium mb-1">
              Multi-tab avg position
            </div>
            <div className="text-2xl font-bold text-amber-700 dark:text-amber-300 tabular-nums">
              #{policyData.multi_avg_position.toLocaleString()}
            </div>
          </div>
        </div>

        <div className="flex items-center gap-4 text-xs text-gray-400 dark:text-gray-500">
          <span className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-sm bg-blue-500 inline-block" />
            Single-tab users
          </span>
          <span className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-sm bg-amber-400 inline-block" />
            Multi-tab users
          </span>
        </div>
      </div>
    </PanelWrapper>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/FairnessPanel.tsx
git commit -m "feat: add FairnessPanel with stacked progress bars, avg position cards, and policy toggle"
```

---

### Task 12: App layout — assemble all panels

**Files:**
- Modify: `dashboard/src/App.tsx`

- [ ] **Step 1: Replace App.tsx**:

```tsx
import React from 'react'
import { TopBar } from './components/TopBar'
import { MetricCards } from './components/MetricCards'
import { ResponseTimeChart } from './components/ResponseTimeChart'
import { LockingComparisonPanel } from './components/LockingComparisonPanel'
import { MultiEventTable } from './components/MultiEventTable'
import { FairnessPanel } from './components/FairnessPanel'

export default function App() {
  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-bg)' }}>
      <TopBar />
      <main className="max-w-screen-xl mx-auto px-4 py-6 flex flex-col gap-4">

        {/* Row 1: 4 metric cards — full width */}
        <MetricCards />

        {/* Row 2: response time chart (2/3) + locking comparison (1/3) */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div className="lg:col-span-2">
            <ResponseTimeChart />
          </div>
          <div className="lg:col-span-1">
            <LockingComparisonPanel />
          </div>
        </div>

        {/* Row 3: multi-event table (2/3) + fairness panel (1/3) */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div className="lg:col-span-2">
            <MultiEventTable />
          </div>
          <div className="lg:col-span-1">
            <FairnessPanel />
          </div>
        </div>

      </main>
    </div>
  )
}
```

- [ ] **Step 2: Remove Vite boilerplate**

```bash
rm -f dashboard/src/App.css
rm -rf dashboard/src/assets/
```

- [ ] **Step 3: Stage deletions**

```bash
git add -u dashboard/src/
```

- [ ] **Step 4: Run all tests**

```bash
cd dashboard && npm test
```
Expected: All tests pass (no TypeScript errors).

- [ ] **Step 4: Run production build to catch type errors**

```bash
cd dashboard && npm run build
```
Expected: `dist/` created, zero TypeScript errors, zero warnings.

- [ ] **Step 5: Smoke-test the dashboard**

```bash
cd dashboard && npm run dev
```
Open http://localhost:5173 and verify:
- TopBar: "Flash Sale Monitor", MOCK badge (amber + animated dot), experiment dropdown, dark toggle
- MetricCards: 4 cards, values change every ~2s
- ResponseTimeChart: 3 colored lines with custom HTML legend above, X-axis in negative seconds
- LockingComparisonPanel: 2 horizontal bar charts separated by divider
- MultiEventTable: 5 rows, success-rate progress bars, colored status badges
- FairnessPanel: stacked progress bar, two position cards, policy toggle switches values
- Experiment dropdown: selecting different experiments dims/highlights different panels
- Dark toggle: all panels, text, and borders adapt
- Resize to 1024px: no horizontal scroll, all panels readable

- [ ] **Step 6: Final commit**

```bash
git add dashboard/src/App.tsx
git commit -m "feat: assemble full dashboard layout — responsive 3-column grid, all 5 panels wired"
```

---

### Task 13: Verification

- [ ] **Step 1: Run full test suite**

```bash
cd dashboard && npm test
```
Expected: All tests pass.

- [ ] **Step 2: Type-check**

```bash
cd dashboard && npx tsc --noEmit
```
Expected: No errors.

- [ ] **Step 3: Final cleanup commit if needed**

```bash
git add -A
git commit -m "chore: final cleanup and type fixes"
```
