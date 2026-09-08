/**
 * BrewPing Relay - Logger
 *
 * Simple structured logger with level filtering.
 * Outputs JSON-ready log lines for production,
 * human-readable lines for development.
 */

import { config } from './config'

export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3,
}

const LEVEL_LABELS: Record<LogLevel, string> = {
  [LogLevel.DEBUG]: 'DEBUG',
  [LogLevel.INFO]: 'INFO',
  [LogLevel.WARN]: 'WARN',
  [LogLevel.ERROR]: 'ERROR',
}

const TAG_COLORS: Record<string, string> = {
  CONNECT: '\x1b[32m',     // green
  DISCONNECT: '\x1b[31m',  // red
  MESSAGE: '\x1b[36m',     // cyan
  HEARTBEAT: '\x1b[33m',   // yellow
  ERROR: '\x1b[31m',       // red
  SYSTEM: '\x1b[35m',      // magenta
}
const RESET = '\x1b[0m'

function currentLevel(): LogLevel {
  const raw = config.logLevel.toLowerCase()
  if (raw === 'debug') return LogLevel.DEBUG
  if (raw === 'warn') return LogLevel.WARN
  if (raw === 'error') return LogLevel.ERROR
  return LogLevel.INFO
}

function formatTime(): string {
  return new Date().toISOString()
}

function log(level: LogLevel, tag: string, message: string, meta?: Record<string, unknown>) {
  if (level < currentLevel()) return

  const time = formatTime()
  const label = LEVEL_LABELS[level]
  const color = TAG_COLORS[tag] || ''

  const metaStr = meta ? ' ' + JSON.stringify(meta) : ''
  console.log(`${time} ${color}[${tag}]${RESET} [${label}] ${message}${metaStr}`)
}

export const logger = {
  debug: (tag: string, msg: string, meta?: Record<string, unknown>) =>
    log(LogLevel.DEBUG, tag, msg, meta),

  info: (tag: string, msg: string, meta?: Record<string, unknown>) =>
    log(LogLevel.INFO, tag, msg, meta),

  warn: (tag: string, msg: string, meta?: Record<string, unknown>) =>
    log(LogLevel.WARN, tag, msg, meta),

  error: (tag: string, msg: string, meta?: Record<string, unknown>) =>
    log(LogLevel.ERROR, tag, msg, meta),
}
