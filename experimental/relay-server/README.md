# BrewPing Relay Prototype (experimental)

> ## ⚠️ Experimental prototype only — not part of the shipped product
>
> **Experimental prototype only. It is not part of the shipped BrewPing product, is not connected
> to any client, and must not be deployed to a public or untrusted network.**
>
> 它只作参考保留：不在产品链路上、不在架构图里、不在 CI / release 的构建范围内，
> 也不在「即将发布」的路线中。
>
> 本服务**尚未接入任何 BrewPing 客户端**（桌面端与移动端都没有连接它的代码），
> 当前仅作为早期原型随源码提供。它存在两个已知问题，在你自行修复前**不要部署到
> 公网或任何不可信网络**：
>
> 1. **没有鉴权**：`AUTH_MODE=anonymous` 时 REST 接口全部放行，WebSocket 只读取
>    `role` / `deviceId` 而不校验身份（见 `src/utils/auth.ts`）。
> 2. **记录消息内容**：中转的消息 payload 会完整写入日志（见 `src/server.ts` 的
>    `logger.info('MESSAGE', ...)`），与 BrewPing 主项目的隐私承诺不一致。
>
> BrewPing 本体是纯本地网络工具：无账号、无 analytics、无自建服务器。

（**停放中的原型**）实时消息中继服务，连接 Desktop Client 和 Agent，实现远程消息转发。
BrewPing 本体不提供公网中继，也没有任何客户端会连接本服务。

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

## Status

Parked. No client is wired to it, and it is excluded from CI, the release workflows, and the
product's security boundary ([SECURITY.md](../../SECURITY.md)). Treat it as a design sketch.

If you want cross-network access today, solve it on your own side — for example with a VPN overlay
such as Tailscale or WireGuard. BrewPing does not operate or endorse that.

## License

MIT — same as the repository ([LICENSE](../../LICENSE)).
