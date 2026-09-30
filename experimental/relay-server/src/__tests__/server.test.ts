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
    // 这组用例跑在 anonymous 模式：显式清掉令牌相关环境变量，
    // 避免与下面「令牌模式」那组互相污染。
    delete process.env.RELAY_TOKEN
    delete process.env.AUTH_MODE
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

// ─── 令牌模式：设置 RELAY_TOKEN 后必须校验 ──────────────

const TOKEN_PORT = 13001
const RELAY_TOKEN = 'test-relay-token'

/** 连一次 WS，返回关闭码（不等待 welcome）。 */
function closeCodeOf(url: string, headers?: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers })
    ws.on('close', (code) => resolve(code))
    ws.on('error', reject)
  })
}

describe('RelayServer (token mode)', () => {
  let server: RelayServer

  beforeAll(async () => {
    process.env.RELAY_TOKEN = RELAY_TOKEN
    delete process.env.AUTH_MODE
    process.env.PORT = String(TOKEN_PORT)
    server = new RelayServer()
    await server.start()
  })

  afterAll(async () => {
    await server.stop()
    delete process.env.RELAY_TOKEN
  })

  it('health check requires the token', async () => {
    const unauthorized = await fetch(`http://localhost:${TOKEN_PORT}/`)
    expect(unauthorized.status).toBe(401)

    const authorized = await fetch(`http://localhost:${TOKEN_PORT}/`, {
      headers: { authorization: `Bearer ${RELAY_TOKEN}` },
    })
    const json = await authorized.json()
    expect(json.status).toBe('ok')
    expect(json.auth).toBe('token')
    expect(json.secure).toBe(true)
  })

  it('rejects a WebSocket handshake without a token', async () => {
    const code = await closeCodeOf(`ws://localhost:${TOKEN_PORT}/ws?role=desktop&deviceId=no-token`)
    expect(code).toBe(4003)
  })

  it('rejects a WebSocket handshake with the wrong token', async () => {
    const code = await closeCodeOf(
      `ws://localhost:${TOKEN_PORT}/ws?role=desktop&deviceId=wrong-token&token=nope`
    )
    expect(code).toBe(4003)
  })

  it('accepts a WebSocket handshake with ?token=', async () => {
    const ws = new WebSocket(
      `ws://localhost:${TOKEN_PORT}/ws?role=desktop&deviceId=query-token&token=${RELAY_TOKEN}`
    )
    const welcome = await new Promise<any>((resolve, reject) => {
      ws.once('message', (data) => resolve(JSON.parse(data.toString())))
      ws.once('error', reject)
    })
    expect(welcome.type).toBe('system')
    expect(welcome.payload.event).toBe('connected')
    ws.close()
  })

  it('accepts a WebSocket handshake with an Authorization header', async () => {
    const ws = new WebSocket(
      `ws://localhost:${TOKEN_PORT}/ws?role=agent&deviceId=header-token`,
      { headers: { authorization: `Bearer ${RELAY_TOKEN}` } }
    )
    const welcome = await new Promise<any>((resolve, reject) => {
      ws.once('message', (data) => resolve(JSON.parse(data.toString())))
      ws.once('error', reject)
    })
    expect(welcome.type).toBe('system')
    expect(welcome.payload.role).toBe('agent')
    ws.close()
  })
})
