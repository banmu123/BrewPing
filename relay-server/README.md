# BrewPing Relay Server

实时消息中继服务，连接 Desktop Client 和 Agent，实现远程消息转发。

## Architecture

```
┌─────────┐    WebSocket    ┌──────────────┐    WebSocket    ┌───────────────┐
│  Agent  │ ←────────────→ │ Relay Server │ ←────────────→ │   Desktop     │
│ (iPhone/│                 │   (Cloud)    │                 │   (Mac)       │
│  Watch) │                 │              │                 │               │
└─────────┘                 └──────────────┘                 └───────────────┘
```

## Quick Start

```bash
# Install
pnpm install

# Development (hot reload)
pnpm dev

# Build
pnpm build

# Production
pnpm start
```

## Docker

```bash
# Build
docker build -t brewping-relay .

# Run
docker run -p 3000:3000 -e PORT=3000 brewping-relay

# Run with custom config
docker run -p 3000:3000 \
  -e PORT=3000 \
  -e LOG_LEVEL=debug \
  -e HEARTBEAT_TIMEOUT=60000 \
  brewping-relay
```

## API

### REST

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check + server status |
| GET | `/devices` | List online devices |
| POST | `/send` | Send message via REST (testing) |

### WebSocket

Connect: `ws://localhost:3000/ws?role=desktop&deviceId=macbook-001`

**Client → Server:**

```json
// Heartbeat
{ "type": "ping" }

// Send message to agent
{
  "type": "message",
  "target": "agent",
  "payload": { "action": "run", "command": "ls -la" }
}

// Send to specific device
{
  "type": "message",
  "target": "desktop",
  "deviceId": "macbook-001",
  "payload": { "action": "open_app", "app": "Safari" }
}
```

**Server → Client:**

```json
// Relayed message
{ "type": "message", "from": "agent-001", "payload": {...} }

// Heartbeat response
{ "type": "pong" }

// Device status
{ "type": "system", "payload": { "event": "device_online", "deviceId": "...", "role": "..." } }
```

## Testing

### Using websocat (CLI)

```bash
# Install websocat
brew install websocat

# Terminal 1: Connect as desktop
websocat "ws://localhost:3000/ws?role=desktop&deviceId=mac-001"

# Terminal 2: Connect as agent
websocat "ws://localhost:3000/ws?role=agent&deviceId=iphone-001"

# Send a message from agent (in Terminal 2)
{"type":"message","target":"desktop","payload":{"action":"open_app","app":"Safari"}}

# Send heartbeat (in either terminal)
{"type":"ping"}
```

### Using curl (REST)

```bash
# Health check
curl http://localhost:3000/

# List devices
curl http://localhost:3000/devices

# Send message via REST
curl -X POST http://localhost:3000/send \
  -H "Content-Type: application/json" \
  -d '{"target":"desktop","payload":{"action":"test"}}'
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Server port |
| `LOG_LEVEL` | `info` | Log level: debug, info, warn, error |
| `HEARTBEAT_INTERVAL` | `30000` | Client ping interval (ms) |
| `HEARTBEAT_TIMEOUT` | `60000` | Disconnect timeout (ms) |
| `AUTH_MODE` | `anonymous` | Auth mode: anonymous (future: apikey, token, jwt) |

## Project Structure

```
src/
├── index.ts              # Entry point
├── server.ts             # HTTP + WebSocket server
├── websocket/
│   ├── connection.ts     # Connection wrapper with metadata
│   ├── manager.ts        # Connection registry & routing
│   └── heartbeat.ts      # Stale connection cleanup
├── types/
│   └── message.ts        # Protocol type definitions
└── utils/
    ├── config.ts         # Environment config
    ├── logger.ts         # Structured logger
    └── auth.ts           # Auth middleware (stub)
```

## License

MIT
