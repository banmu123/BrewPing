/**
 * BrewPing Relay - Message Protocol Types
 *
 * All messages between Agent, Desktop, and Relay Server
 * use a unified JSON format described here.
 */

// ─── Roles ────────────────────────────────────────────

/** Device role: agent generates commands, desktop executes them */
export type DeviceRole = 'agent' | 'desktop'

// ─── Client → Server ─────────────────────────────────

/** Base message from client to server */
export interface ClientMessage {
  type: ClientMessageType
  target?: DeviceRole       // which role to forward to
  deviceId?: string         // specific device to target (optional)
  payload?: Record<string, unknown>
}

export type ClientMessageType =
  | 'message'   // data message to be relayed
  | 'ping'      // heartbeat ping

// ─── Server → Client ─────────────────────────────────

/** Base message from server to client */
export interface ServerMessage {
  type: ServerMessageType
  from?: string             // deviceId of sender
  payload?: Record<string, unknown>
}

export type ServerMessageType =
  | 'message'   // relayed data message
  | 'pong'      // heartbeat pong
  | 'error'     // error notification
  | 'system'    // system notification (device online/offline)

// ─── Connection Metadata ─────────────────────────────

export interface ConnectionMeta {
  deviceId: string
  role: DeviceRole
  connectedAt: number
  lastHeartbeat: number
  ip?: string
}

// ─── REST API Responses ──────────────────────────────

export interface DeviceInfo {
  deviceId: string
  role: DeviceRole
  online: boolean
  connectedAt: number
  lastHeartbeat: number
}

export interface StatusResponse {
  status: 'ok'
  service: string
  version: string
  uptime: number
  devices: number
  auth: string
}
