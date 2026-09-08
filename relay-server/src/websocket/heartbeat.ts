/**
 * BrewPing Relay - Heartbeat Monitor
 *
 * Periodically checks all connections for stale heartbeats.
 * If a client hasn't sent a ping within HEARTBEAT_TIMEOUT ms,
 * the connection is terminated.
 *
 * Flow:
 *   Client sends:  { "type": "ping" }
 *   Server replies: { "type": "pong" }
 *   If no ping for TIMEOUT ms → force disconnect
 */

import { ConnectionManager } from './manager'
import { logger } from '../utils/logger'
import { config } from '../utils/config'

export class HeartbeatMonitor {
  private manager: ConnectionManager
  private interval: ReturnType<typeof setInterval> | null = null

  constructor(manager: ConnectionManager) {
    this.manager = manager
  }

  /** Start the periodic heartbeat check */
  start(): void {
    if (this.interval) return

    const checkInterval = Math.max(config.heartbeatTimeout / 2, 10000)

    this.interval = setInterval(() => {
      this.checkAll()
    }, checkInterval)

    logger.info('HEARTBEAT', `monitor started (check every ${checkInterval}ms, timeout ${config.heartbeatTimeout}ms)`)
  }

  /** Stop the heartbeat check */
  stop(): void {
    if (this.interval) {
      clearInterval(this.interval)
      this.interval = null
    }
  }

  /** Check all connections for stale heartbeats */
  private checkAll(): void {
    const timeout = config.heartbeatTimeout
    let staleCount = 0

    for (const device of this.manager.getDevices()) {
      const idleMs = Date.now() - device.lastHeartbeat

      if (idleMs > timeout) {
        staleCount++
        logger.warn('HEARTBEAT', `stale connection, disconnecting`, {
          deviceId: device.deviceId,
          role: device.role,
          idleMs: Math.round(idleMs / 1000) + 's',
        })
        const conn = this.manager.getConnection(device.deviceId)
        conn?.close(4001, 'heartbeat timeout')
        this.manager.remove(device.deviceId)
      }
    }

    if (staleCount > 0) {
      logger.info('HEARTBEAT', `cleaned ${staleCount} stale connection(s)`)
    }
  }
}
