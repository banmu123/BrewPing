# BrewPing

远程 AI 编程助手 — 在同一局域网内，用 iPhone / Apple Watch 控制你自己 Mac 上的 AI 编程 Agent。

## 简介

BrewPing 让你在 iPhone 或 Apple Watch 上操控**你自己 Mac** 上运行的命令行 AI 编程 Agent：发送指令、查看执行状态、接收结果，不必守在电脑前。

> **网络范围说明**：iPhone 与 Mac 必须在**同一局域网**（同一 Wi-Fi）。BrewPing 不提供公网中继，也不会连接到你不拥有的设备。

## 架构

```
┌─────────────┐    HTTP API     ┌──────────────────┐
│   iPhone    │ ◄────────────►  │  BrewPing Desktop │
│   (iOS)     │   Bonjour       │  (macOS Menu Bar) │
└──────┬──────┘   Auto-Discovery└────────┬─────────┘
       │                                  │
       │ WatchConnectivity                │ PTY / CLI
       │                                  │
┌──────┴──────┐                  ┌────────┴─────────┐
│ Apple Watch │                  │   AI Agents      │
│  (watchOS)  │                  │  CLI coding       │
└─────────────┘                  │  agents           │
                                 └──────────────────┘
```

## 功能

### macOS Desktop
- 菜单栏常驻应用，显示设备信息和 Agent 状态
- 多 Agent Tab 终端界面，支持实时输出
- 自动发现已安装的 AI Agent（按各自 CLI 的可执行文件识别）
- HTTP API 供 iPhone 远程连接
- Bonjour/mDNS 自动广播，iPhone 无需手动输入 IP

### iPhone
- 自动发现局域网内的 Mac 设备
- 多设备管理（支持 Mac/Windows/Linux）
- 远程查看 Agent 列表、切换默认 Agent
- 切换当前 Agent 使用的模型（列出已配置的可选项，选择后立即生效）
- 发送消息并实时查看执行结果
- 管理 Session 生命周期（启动/停止）
- Watch 语音指令转发

### Apple Watch
- 语音输入转文字发送指令
- 左右滑动切换不同 Agent
- 左右切换当前 Agent 的模型
- 上下滑动切换不同设备
- 实时查看命令执行状态

## 支持的 AI Agent

下表仅用于说明**兼容性**，产品名称与商标归各自所有者所有（见文末免责声明）。

| Agent | 模式 | 命令 |
|-------|------|------|
| OpenCode | Session（交互式） | `opencode` |
| Claude Code | Headless（一次性） | `claude` |
| Codex CLI | Headless（一次性） | `codex` |
| Aider | Headless（一次性） | `aider` |

## 系统要求

- **macOS Desktop**: macOS 13.0+
- **iPhone**: iOS 17.0+
- **Apple Watch**: watchOS 9.0+
- iPhone 和 Mac 需在同一局域网

## 快速开始

### 1. 安装 Desktop

```bash
# 从源码构建
swift build -c release
open .build/release/
```

或直接使用预构建的 `BrewPing Desktop.app`。

### 2. 安装至少一个 AI Agent

```bash
# OpenCode
curl -fsSL https://get.opencode.ai | sh

# Claude Code
npm install -g @anthropic-ai/claude-code

# Codex CLI
npm install -g @openai/codex
```

### 3. 启动 Desktop

双击 `BrewPing Desktop.app`，菜单栏出现 ☕ 图标即表示已就绪。

### 4. 连接 iPhone

1. 在 BrewPing Desktop 菜单栏里点 **Pairing Code**，拿到 6 位配对码；
2. 打开 BrewPing iPhone 应用，点 **Add Device**（或用「Auto Discover」找到 Mac）；
3. 填好 Host / Port 与配对码，点 **Add**。

配对成功后，配对密钥保存在 iOS Keychain；之后所有 `api/*` 请求都会带 `Authorization: Bearer <token>`。

### 没有 Mac 也想先看看界面？

在 iPhone 端点 **Try Demo Mode**（或 Add Device → Add Demo Device），即可在完全没有硬件的情况下走通「添加设备 → 看到 Agent → 启动会话 → 发送命令 → 收到结果」全流程。


## 项目结构

```
BrewPing/
├── Package.swift                    # SwiftPM 配置
├── Sources/
│   ├── App/                         # Desktop 核心逻辑
│   │   ├── BrewPingAgent.swift      # Agent 主循环
│   │   ├── DesktopCore.swift        # Desktop 生命周期管理
│   │   ├── HTTPAPI.swift            # HTTP API 路由
│   │   ├── HTTPServer.swift         # NWListener HTTP 服务器
│   │   └── BonjourAdvertiser.swift  # mDNS 广播
│   ├── Agents/                      # Agent 发现与管理
│   │   ├── AgentDiscovery.swift     # 自动扫描已安装 Agent
│   │   ├── AgentManager.swift       # Agent 切换与状态管理
│   │   └── OpenCodeAgent.swift      # PTY 交互式 Agent
│   ├── Protocol/                    # 通信协议
│   ├── Session/                     # Session 生命周期
│   ├── Terminal/                    # 终端状态模型
│   ├── BrewPing/                    # CLI 工具
│   └── BrewPingDesktop/             # macOS SwiftUI 应用
│       ├── BrewPingDesktopApp.swift # App 入口
│       ├── MenuBarView.swift        # 菜单栏 UI
│       ├── TerminalWindow.swift     # 终端窗口
│       └── AgentTerminalView.swift  # 终端输出视图
├── ios/
│   ├── BrewPing/                    # iPhone 应用
│   └── Watch/                       # Apple Watch 应用
└── build/
    └── BrewPing Desktop.app         # 预构建应用
```

## API 端点

除 `/api/pair` 与 `/api/status` 外，所有接口都要求 `Authorization: Bearer <token>`；
写操作还需要 `X-BrewPing-Timestamp` 与 `X-BrewPing-Nonce` 头（防重放，时间窗 120 秒）。

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| POST | `/api/pair` | 否 | 用 6 位配对码换取长期 token |
| GET | `/api/status` | 否 | 设备状态（只读健康检查） |
| GET | `/api/agents` | 是 | Agent 列表 |
| POST | `/api/message` | 是 | 发送消息 |
| GET | `/api/message/:id` | 是 | 查询命令状态 |
| POST | `/api/agents/default` | 是 | 设置默认 Agent |
| POST | `/api/agents/:id/switch` | 是 | 切换 Agent |
| GET | `/api/agents/:id/models` | 是 | 该 Agent 的可切换模型（Provider → Models 两层） |
| POST | `/api/agents/models/default` | 是 | 设置默认模型（body: `{"agentId","modelId"}`） |
| POST | `/api/session/start` | 是 | 启动 Session |
| POST | `/api/session/stop` | 是 | 停止 Session |

## 配置

配置文件位于 `~/.brewping/`:

- `device.json` — 设备身份（Device ID、名称）
- `pairing.json` — 配对 token 与临时配对码（文件权限 0600）
- `config.json` — Agent 配置（默认 Agent、模型偏好）
- `session.json` — 当前 Session 状态

## 免责声明 / Trademarks

OpenCode、Claude、Claude Code、Codex、Aider 等名称是其各自所有者的商标。
BrewPing 与这些厂商**没有任何隶属、赞助或背书关系**；文中提及这些名称仅用于说明兼容性。

BrewPing 只连接你**自己配置**的、位于同一局域网的设备，不会连接第三方设备，也不提供公网中继。

## License

MIT
