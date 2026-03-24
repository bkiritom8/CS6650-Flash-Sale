import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useWebSocket } from './useWebSocket'

class MockWebSocket {
  static OPEN = 1
  url: string
  readyState = MockWebSocket.OPEN
  onopen: (() => void) | null = null
  onmessage: ((e: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  close = vi.fn()
  constructor(url: string) {
    this.url = url
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
