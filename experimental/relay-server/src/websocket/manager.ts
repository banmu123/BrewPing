/**
 * BrewPing Relay - Connection Manager
 *
 * Central registry of all connected devices.
 * Handles:
 *   - Adding / removing connections
 *   - Looking up by deviceId
 *   - Sending to a specific device or role
 *   - Broadcasting to all
 *   - Notifying others when a device goes online/offline
 */

import { Connection } from './connection'
import { logger } from '../utils/logger'
import type { DeviceRole, DeviceInfo, ServerMessage } from '../types/message'

export class ConnectionManager {
  /** All active connections keyed by deviceId */
  private connections = new Map<string, Connection>()

  // ─── Add / Remove ──────────────────────────────────

  /** Register a new connection. Closes any existing connection with the same deviceId. */
  add(connection: Connection): void {
    const { deviceId, role } = connection.meta

    // Close duplicate if exists (device reconnecting)
    const existing = this.connections.get(deviceId)
    if (existing) {
      logger.info('SYSTEM', `device reconnecting, closing old connection`, { deviceId })
      existing.close(4000, 'replaced by new connection')
      this.connections.delete(deviceId)
    }

    this.connections.set(deviceId, connection)
    logger.info('CONNECT', `${role} device connected`, { deviceId, role })

    // Notify all other devices about the new connection
    this.broadcastSystem({
      type: 'system',
      payload: { event: 'device_online', deviceId, role },
    }, deviceId)
  }

  /** Remove a connection by deviceId */
  remove(deviceId: string): void {
    const conn = this.connections.get(deviceId)
    if (!conn) return

    const { role } = conn.meta
    this.connections.delete(deviceId)
    logger.info('DISCONNECT', `${role} device disconnected`, { deviceId, role })

    // Notify remaining devices
    this.broadcastSystem({
      type: 'system',
      payload: { event: 'device_offline', deviceId, role },
    }, deviceId)
  }

  // ─── Lookup ────────────────────────────────────────

  /** Get connection by deviceId */
  getConnection(deviceId: string): Connection | undefined {
    return this.connections.get(deviceId)
  }

  /** Get all connections for a given role */
  getConnectionsByRole(role: DeviceRole): Connection[] {
    return Array.from(this.connections.values()).filter(c => c.meta.role === role)
  }

  /** Get first connection of a role (convenience) */
  getFirstByRole(role: DeviceRole): Connection | undefined {
    return Array.from(this.connections.values()).find(c => c.meta.role === role)
  }

  /** Total connected devices */
  get size(): number {
    return this.connections.size
  }

  /** All connected devices as DeviceInfo[] */
  getDevices(): DeviceInfo[] {
    return Array.from(this.connections.values()).map(c => ({
      deviceId: c.meta.deviceId,
      role: c.meta.role,
      online: c.alive,
      connectedAt: c.meta.connectedAt,
      lastHeartbeat: c.meta.lastHeartbeat,
    }))
  }

  // ─── Sending ───────────────────────────────────────

  /** Send a message to a specific deviceId */
  sendToDevice(deviceId: string, message: ServerMessage): boolean {
    const conn = this.connections.get(deviceId)
    if (!conn) return false
    return conn.send(message)
  }

  /** Send a message to all connections with the given role */
  sendToRole(role: DeviceRole, message: ServerMessage): number {
    let sent = 0
    for (const conn of this.connections.values()) {
      if (conn.meta.role === role && conn.send(message)) sent++
    }
    return sent
  }

  /** Broadcast a message to all connected devices */
  broadcast(message: ServerMessage, excludeDeviceId?: string): void {
    for (const [deviceId, conn] of this.connections) {
      if (deviceId !== excludeDeviceId) {
        conn.send(message)
      }
    }
  }

  /** Broadcast a system message (online/offline notifications) */
  private broadcastSystem(message: ServerMessage, excludeDeviceId?: string): void {
    this.broadcast(message, excludeDeviceId)
  }
}
