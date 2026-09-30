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

  /**
   * 共享令牌（`RELAY_TOKEN`）。
   *
   * 设置后中继要求每个连接出示同一令牌：REST 走 `Authorization: Bearer …`
   * 或 `X-Relay-Token`，WebSocket 走升级请求头或 `?token=`。
   * **未设置**时退回 `anonymous`（全放行）—— 仅供本机 / 内网联调，
   * 启动时会打印一条告警。
   */
  get relayToken() { return process.env.RELAY_TOKEN || '' },

  /**
   * 鉴权模式。显式 `AUTH_MODE` 优先；否则按是否配置了 `RELAY_TOKEN` 推断：
   * 配了令牌就强制校验，没配就是 anonymous。
   */
  get authMode() {
    const explicit = process.env.AUTH_MODE
    if (explicit) return explicit
    return process.env.RELAY_TOKEN ? 'token' : 'anonymous'
  },
}
