/**
 * BrewPing Relay - Connection Wrapper
 *
 * Wraps a raw WebSocket with metadata and send helpers.
 * Each connected device gets one Connection instance.
 */

import WebSocket from 'ws'
import type { ConnectionMeta, ServerMessage, DeviceRole } from '../types/message'

export class Connection {
  readonly meta: ConnectionMeta
  readonly ws: WebSocket

  constructor(ws: WebSocket, deviceId: string, role: DeviceRole, ip?: string) {
    this.ws = ws
    this.meta = {
      deviceId,
      role,
      connectedAt: Date.now(),
      lastHeartbeat: Date.now(),
      ip,
    }
  }

  /** Update last heartbeat timestamp */
  heartbeat(): void {
    this.meta.lastHeartbeat = Date.now()
  }

  /** Send a JSON message to this connection */
  send(message: ServerMessage): boolean {
    if (this.ws.readyState !== WebSocket.OPEN) return false
    try {
      this.ws.send(JSON.stringify(message))
      return true
    } catch {
      return false
    }
  }

  /** Check if the underlying socket is still open */
  get alive(): boolean {
    return this.ws.readyState === WebSocket.OPEN
  }

  /** Time since last heartbeat (ms) */
  get idleMs(): number {
    return Date.now() - this.meta.lastHeartbeat
  }

  /** Close the connection gracefully */
  close(code = 1000, reason = 'server closing'): void {
    try {
      this.ws.close(code, reason)
    } catch {
      // already closed
    }
  }
}
