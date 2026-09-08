/**
 * BrewPing Relay - Auth Middleware (Stub)
 *
 * Currently operates in "anonymous" mode.
 * Structured to support API Key, Device Token, and JWT in future phases.
 */

import type { Request, Response, NextFunction } from 'express'
import { config } from './config'
import { logger } from './logger'

export interface AuthResult {
  authenticated: boolean
  mode: string
  deviceId?: string
}

/**
 * REST API auth middleware.
 * Currently a no-op that passes all requests through.
 */
export function authMiddleware(req: Request, res: Response, next: NextFunction): void {
  const mode = config.authMode

  if (mode === 'anonymous') {
    // Anonymous mode — allow all requests
    next()
    return
  }

  // Future: API Key mode
  // const apiKey = req.headers['x-api-key'] as string
  // if (!apiKey) return res.status(401).json({ error: 'missing api key' })

  // Future: JWT mode
  // const token = req.headers.authorization?.replace('Bearer ', '')
  // if (!token) return res.status(401).json({ error: 'missing token' })

  next()
}

/**
 * WebSocket auth check.
 * Extracts role and deviceId from query params.
 * Returns null if invalid.
 */
export function parseWsAuth(url: string): { role: string; deviceId: string } | null {
  try {
    const parsed = new URL(url, 'http://localhost')
    const role = parsed.searchParams.get('role')
    const deviceId = parsed.searchParams.get('deviceId')

    if (!role || !deviceId) return null
    if (role !== 'agent' && role !== 'desktop') return null

    return { role, deviceId }
  } catch {
    return null
  }
}
