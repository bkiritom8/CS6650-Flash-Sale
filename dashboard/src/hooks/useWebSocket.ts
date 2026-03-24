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
