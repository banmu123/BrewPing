/**
 * BrewPing Relay - Config
 *
 * Centralized configuration from environment variables.
 * Uses getter functions so tests can override env vars after import.
 */

import dotenv from 'dotenv'
dotenv.config()

export const config = {
  get port() { return parseInt(process.env.PORT || '3000', 10) },
  get logLevel() { return process.env.LOG_LEVEL || 'info' },
  get heartbeatInterval() { return parseInt(process.env.HEARTBEAT_INTERVAL || '30000', 10) },
  get heartbeatTimeout() { return parseInt(process.env.HEARTBEAT_TIMEOUT || '60000', 10) },
  get authMode() { return process.env.AUTH_MODE || 'anonymous' },
}
