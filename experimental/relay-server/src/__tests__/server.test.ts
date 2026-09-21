/**
 * BrewPing Relay - Basic Tests
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { RelayServer } from '../server'
import WebSocket from 'ws'

const PORT = 13000

/** Connect and return ws + first message (welcome) */
function connect(role: string, deviceId: string): Promise<{ ws: WebSocket; welcome: any }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://localhost:${PORT}/ws?role=${role}&deviceId=${deviceId}`)
    ws.once('message', (data) => {
      resolve({ ws, welcome: JSON.parse(data.toString()) })
    })
    ws.once('error', reject)
  })
}

function waitForMessage(ws: WebSocket, timeout = 3000): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), timeout)
    ws.once('message', (data) => {
      clearTimeout(timer)
      resolve(JSON.parse(data.toString()))
    })
  })
}

function send(ws: WebSocket, msg: any): void {
  ws.send(JSON.stringify(msg))
}

describe('RelayServer', () => {
  let server: RelayServer

  beforeAll(async () => {
    process.env.PORT = String(PORT)
    server = new RelayServer()
    await server.start()
  })

  afterAll(async () => {
    await server.stop()
  })

  it('health check returns ok', async () => {
    const res = await fetch(`http://localhost:${PORT}/`)
    const json = await res.json()
    expect(json.status).toBe('ok')
    expect(json.service).toBe('BrewPing Relay Server')
  })

  it('devices endpoint returns array', async () => {
    const res = await fetch(`http://localhost:${PORT}/devices`)
    const json = await res.json()
    expect(Array.isArray(json)).toBe(true)
  })

  it('rejects connection without role', async () => {
    const ws = new WebSocket(`ws://localhost:${PORT}/ws`)
    const code = await new Promise<number>((resolve) => {
      ws.on('close', (c) => resolve(c))
    })
    expect(code).toBe(4002)
  })

  it('accepts valid connection and sends welcome', async () => {
    const { ws, welcome } = await connect('desktop', 'test-mac')
    expect(welcome.type).toBe('system')
    expect(welcome.payload.event).toBe('connected')
    ws.close()
  })

  it('relays message from agent to desktop', async () => {
    const d = await connect('desktop', 'test-mac-2')
    const a = await connect('agent', 'test-iphone')

    await new Promise(r => setTimeout(r, 100))

    send(a.ws, { type: 'message', target: 'desktop', payload: { action: 'test' } })

    const received = await waitForMessage(d.ws)
    expect(received.type).toBe('message')
    expect(received.from).toBe('test-iphone')
    expect(received.payload.action).toBe('test')

    d.ws.close()
    a.ws.close()
  })

  it('responds to ping with pong', async () => {
    const { ws } = await connect('desktop', 'test-ping')
    send(ws, { type: 'ping' })
    const pong = await waitForMessage(ws)
    expect(pong.type).toBe('pong')
    ws.close()
  })
})
