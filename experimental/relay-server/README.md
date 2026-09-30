# BrewPing Relay Prototype (experimental)

> ## ⚠️ Experimental prototype — not part of the shipped product
>
> **Experimental prototype only. It is not part of the shipped BrewPing product and must not be
> deployed to a public or untrusted network without you having reviewed it yourself.**
>
> 它只作参考保留：不在产品链路上、不在架构图里、不在 CI / release 的构建范围内，
> 也不在「即将发布」的路线中。
>
> 本服务**默认不对任何客户端开放能力**：只有显式配置了中继地址的桌面端
> （`~/.brewping/relay.json`）与在 App 内开启「远程访问（实验）」的 iPhone 才会连接它。
> 桌面端默认关闭远程，行为与之前完全一致。
>
> 已知边界（自行评估后再决定是否部署）：
>
> 1. **共享令牌，而非设备级鉴权**：设置 `RELAY_TOKEN` 后中继会校验**同一**共享令牌
>    （REST 用 `Authorization: Bearer …` / `X-Relay-Token`，WebSocket 用升级头或 `?token=`）；
>    未设置时退回 `anonymous`（全放行，启动会告警）。设备级身份仍然由 BrewPing 自己的
>    配对令牌在桌面端校验 —— 中继只是透传，不构成设备鉴权。
> 2. **传输未加密（裸 `ws://` / `http://`）**：跨公网部署请自行在前置反向代理上终止
>    TLS（`wss://`），并自行加限流与可观测性。
> 3. **不做 rate limit / 防滥用**，也没有生产级的可观测性。
>
> ✅ **消息内容不落盘**：中继只记录路由元数据（`from` / `targetRole` / `bytes`），
> 不写 payload 内容，与 BrewPing 主项目的隐私承诺保持一致（见 `src/server.ts`）。
>
> BrewPing 本体仍是纯本地网络工具：无账号、无 analytics、无自建服务器。

（**停放中的原型**）实时消息中继服务，用于把桌面端与 iPhone 之间的 HTTP 调用隧道化，
从而支持跨网络访问。BrewPing 本体的默认工作方式是局域网直连，远程访问是可选扩展。

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
| `RELAY_TOKEN` | *(empty)* | Shared token. Setting it switches the server to `token` mode; every REST call and WebSocket handshake must present it |
| `AUTH_MODE` | derived | `token` when `RELAY_TOKEN` is set, otherwise `anonymous`. Set explicitly only to force one |

## Running with a token

```bash
RELAY_TOKEN="$(openssl rand -hex 24)" pnpm start

# Clients then present the same value:
#   WebSocket: Authorization: Bearer <token>   (or ?token=<token>)
#   REST:      Authorization: Bearer <token>   (or X-Relay-Token: <token>)
```

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

Parked prototype, but now reachable from the product on an **opt-in, off-by-default** basis:

- the macOS desktop connects to it only when `~/.brewping/relay.json` (or `BREWPING_RELAY_URL`)
  is configured, and that connection carries the whole local HTTP API over the tunnel;
- the iPhone app connects only when the user switches on **Remote Access (experimental)** and
  enters a relay address; requests are then tunneled and fall back to the local network when the
  relay is unreachable.

It is still excluded from CI, the release workflows, and the product's security boundary
([SECURITY.md](../../SECURITY.md)). Treat it as a prototype with a real client path.

If you want cross-network access without running this, solve it on your own side — for example with
a VPN overlay such as Tailscale or WireGuard. BrewPing does not operate or endorse that.

## License

MIT — same as the repository ([LICENSE](../../LICENSE)).
