/**
 * BrewPing Relay - Server
 *
 * Sets up Express HTTP server + WebSocket server.
 * Handles:
 *   - WebSocket upgrade, message routing, disconnect
 *   - REST API endpoints (/ and /devices)
 *   - Auth middleware (stub)
 */

import http from 'http'
import express from 'express'
import { WebSocketServer, WebSocket } from 'ws'
import { ConnectionManager } from './websocket/manager'
import { Connection } from './websocket/connection'
import { HeartbeatMonitor } from './websocket/heartbeat'
import { authMiddleware, parseWsAuth } from './utils/auth'
import { logger } from './utils/logger'
import { config } from './utils/config'
import type { ClientMessage, ServerMessage, DeviceRole } from './types/message'

export class RelayServer {
  private app: express.Application
  private server: http.Server
  private wss: WebSocketServer
  private manager: ConnectionManager
  private heartbeat: HeartbeatMonitor
  private startedAt = Date.now()

  constructor() {
    this.app = express()
    this.server = http.createServer(this.app)
    this.wss = new WebSocketServer({ server: this.server, path: '/ws' })
    this.manager = new ConnectionManager()
    this.heartbeat = new HeartbeatMonitor(this.manager)

    this.setupHttp()
    this.setupWebSocket()
  }

  // ─── HTTP Routes ───────────────────────────────────

  private setupHttp(): void {
    this.app.use(express.json())
    this.app.use(authMiddleware)

    /** Health check */
    this.app.get('/', (_req, res) => {
      res.json({
        status: 'ok',
        service: 'BrewPing Relay Server',
        version: '1.0.0',
        uptime: Math.round((Date.now() - this.startedAt) / 1000),
        devices: this.manager.size,
        auth: config.authMode,
      })
    })

    /** List online devices */
    this.app.get('/devices', (_req, res) => {
      res.json(this.manager.getDevices())
    })

    /** Send a message via REST (for testing) */
    this.app.post('/send', (req, res) => {
      const { target, payload } = req.body
      if (!target || !payload) {
        res.status(400).json({ error: 'missing target or payload' })
        return
      }

      const sent = this.manager.sendToRole(target as DeviceRole, {
        type: 'message',
        from: 'api',
        payload,
      })

      res.json({ ok: true, delivered: sent })
    })
  }

  // ─── WebSocket ─────────────────────────────────────

  private setupWebSocket(): void {
    this.wss.on('connection', (ws, req) => {
      const ip = req.socket.remoteAddress

      // Parse auth from query params
      const auth = parseWsAuth(req.url || '')
      if (!auth) {
        logger.warn('CONNECT', 'rejected: missing role or deviceId', { url: req.url })
        ws.close(4002, 'missing role or deviceId')
        return
      }

      const { role, deviceId } = auth

      // Create and register the connection
      const conn = new Connection(ws, deviceId, role as DeviceRole, ip)
      this.manager.add(conn)

      // Send welcome message
      conn.send({
        type: 'system',
        payload: {
          event: 'connected',
          deviceId,
          role,
          server: 'BrewPing Relay Server',
        },
      })

      // Handle incoming messages
      ws.on('message', (data) => {
        this.handleMessage(conn, data.toString())
      })

      // Handle disconnect
      ws.on('close', (code, reason) => {
        this.manager.remove(deviceId)
        logger.debug('DISCONNECT', `close code=${code} reason=${reason}`)
      })

      // Handle errors
      ws.on('error', (err) => {
        logger.error('ERROR', `ws error for ${deviceId}: ${err.message}`)
      })
    })
  }

  /** Process an incoming message from a connected client */
  private handleMessage(conn: Connection, raw: string): void {
    let msg: ClientMessage
    try {
      msg = JSON.parse(raw)
    } catch {
      conn.send({ type: 'error', payload: { error: 'invalid JSON' } })
      return
    }

    const { deviceId, role } = conn.meta

    // ─── Heartbeat: ping → pong ───
    if (msg.type === 'ping') {
      conn.heartbeat()
      conn.send({ type: 'pong' })
      logger.debug('HEARTBEAT', `pong → ${deviceId}`)
      return
    }

    // ─── Data message: relay to target ───
    if (msg.type === 'message') {
      conn.heartbeat() // treat any message as heartbeat

      const targetRole = msg.target || (role === 'agent' ? 'desktop' : 'agent')

      const relayMsg: ServerMessage = {
        type: 'message',
        from: deviceId,
        payload: msg.payload,
      }

      logger.info('MESSAGE', `${role} → ${targetRole}`, {
        from: deviceId,
        targetRole,
        payload: msg.payload,
      })

      // If a specific deviceId is targeted, send to that device only
      if (msg.deviceId) {
        const sent = this.manager.sendToDevice(msg.deviceId, relayMsg)
        if (!sent) {
          conn.send({ type: 'error', payload: { error: `device ${msg.deviceId} not found` } })
        }
        return
      }

      // Otherwise broadcast to all devices of the target role
      const sent = this.manager.sendToRole(targetRole as DeviceRole, relayMsg)
      if (sent === 0) {
        conn.send({
          type: 'error',
          payload: { error: `no ${targetRole} devices online` },
        })
      }
      return
    }

    // Unknown message type
    conn.send({ type: 'error', payload: { error: `unknown message type: ${msg.type}` } })
  }

  // ─── Lifecycle ─────────────────────────────────────

  /** Start the server */
  start(): Promise<void> {
    return new Promise((resolve) => {
      this.server.listen(config.port, () => {
        logger.info('SYSTEM', `BrewPing Relay Server listening on port ${config.port}`)
        logger.info('SYSTEM', `WebSocket endpoint: ws://localhost:${config.port}/ws`)
        logger.info('SYSTEM', `Auth mode: ${config.authMode}`)
        this.heartbeat.start()
        resolve()
      })
    })
  }

  /** Stop the server gracefully */
  stop(): Promise<void> {
    return new Promise((resolve) => {
      this.heartbeat.stop()

      // Close all WebSocket connections
      for (const device of this.manager.getDevices()) {
        const conn = this.manager.getConnection(device.deviceId)
        conn?.close(1001, 'server shutting down')
      }

      this.wss.close(() => {
        this.server.close(() => {
          logger.info('SYSTEM', 'server stopped')
          resolve()
        })
      })
    })
  }
}
