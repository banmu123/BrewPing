/**
 * BrewPing Relay - Auth
 *
 * 两种模式：
 *  - `token`（设置 `RELAY_TOKEN` 即生效，推荐）：REST 与 WebSocket 都必须出示同一共享令牌；
 *  - `anonymous`（未配置令牌时的默认值）：全放行，仅限本机 / 内网联调，启动时会告警。
 *
 * 边界说明：共享令牌只回答「谁能连上中继」。设备级身份仍由 BrewPing 自己的配对令牌
 * （Bearer + 时间戳 + nonce）在桌面端校验 —— 中继原样转发这些头，自己不解析、不校验、
 * 也不缓存 payload。
 */

import { timingSafeEqual } from 'crypto'
import type { Request, Response, NextFunction } from 'express'
import { config } from './config'
import { logger } from './logger'

export interface AuthResult {
  authenticated: boolean
  mode: string
  deviceId?: string
}

/** WebSocket 握手参数：角色、设备号，以及可选的令牌。 */
export interface WsAuth {
  role: 'agent' | 'desktop'
  deviceId: string
  /** `?token=` 携带的令牌（可为空；升级请求头里的令牌由调用方另取）。 */
  token: string | null
}

/** 常量时间比较，避免按字符提前返回、泄露令牌前缀。 */
export function tokenEquals(a: string, b: string): boolean {
  const bufA = Buffer.from(a, 'utf8')
  const bufB = Buffer.from(b, 'utf8')
  if (bufA.length !== bufB.length) return false
  return timingSafeEqual(bufA, bufB)
}

/** 校验出示的令牌。`anonymous` 模式一律通过。 */
export function authorizeToken(presented: string | null | undefined): { ok: boolean; error?: string } {
  if (config.authMode !== 'token') return { ok: true }
  const expected = config.relayToken
  if (!expected) return { ok: false, error: 'server misconfigured: token mode without RELAY_TOKEN' }
  if (!presented) return { ok: false, error: 'missing relay token' }
  if (!tokenEquals(presented, expected)) return { ok: false, error: 'invalid relay token' }
  return { ok: true }
}

/** 从 `Authorization: Bearer …` / `X-Relay-Token` 取令牌。两者都支持：原生客户端用其一即可。 */
export function presentedTokenFromHeaders(headers: Record<string, unknown>): string | null {
  const relayToken = headers['x-relay-token']
  if (typeof relayToken === 'string' && relayToken) return relayToken
  const authorization = headers['authorization']
  if (typeof authorization === 'string' && authorization) {
    const match = /^Bearer\s+(.+)$/i.exec(authorization.trim())
    if (match) return match[1].trim()
  }
  return null
}

/**
 * REST API auth middleware.
 * `anonymous` 模式是 no-op；`token` 模式要求出示令牌，否则 401。
 */
export function authMiddleware(req: Request, res: Response, next: NextFunction): void {
  if (config.authMode !== 'token') {
    next()
    return
  }

  const decision = authorizeToken(presentedTokenFromHeaders(req.headers as Record<string, unknown>))
  if (!decision.ok) {
    logger.warn('AUTH', `rejected REST request: ${decision.error}`)
    res.status(401).json({ error: decision.error })
    return
  }

  next()
}

/**
 * WebSocket auth check.
 * Extracts role and deviceId from query params.
 * Returns null if invalid.
 */
export function parseWsAuth(url: string): WsAuth | null {
  try {
    const parsed = new URL(url, 'http://localhost')
    const role = parsed.searchParams.get('role')
    const deviceId = parsed.searchParams.get('deviceId')

    if (!role || !deviceId) return null
    if (role !== 'agent' && role !== 'desktop') return null

    return { role, deviceId, token: parsed.searchParams.get('token') }
  } catch {
    return null
  }
}
