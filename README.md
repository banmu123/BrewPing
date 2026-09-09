# BrewPing

远程 AI 编程助手 — 通过 iPhone / Apple Watch 控制 Mac 上的 AI Agent。

## 简介

BrewPing 让你在 iPhone 或 Apple Watch 上远程操控 Mac 上运行的 AI 编程工具（OpenCode、Claude Code、Codex、Aider）。无需坐在电脑前，随时随地发送指令、查看结果。

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
│  (watchOS)  │                  │  OpenCode/Claude/ │
└─────────────┘                  │  Codex/Aider      │
                                 └──────────────────┘
```

## 功能

### macOS Desktop
- 菜单栏常驻应用，显示设备信息和 Agent 状态
- 多 Agent Tab 终端界面，支持实时输出
- 自动发现已安装的 AI Agent（OpenCode、Claude Code、Codex、Aider）
- HTTP API 供 iPhone 远程连接
- Bonjour/mDNS 自动广播，iPhone 无需手动输入 IP

### iPhone
- 自动发现局域网内的 Mac 设备
- 多设备管理（支持 Mac/Windows/Linux）
- 远程查看 Agent 列表、切换默认 Agent
- 发送消息并实时查看执行结果
- 管理 Session 生命周期（启动/停止）
- Watch 语音指令转发

### Apple Watch
- 语音输入转文字发送指令
- 左右滑动切换不同 Agent
- 上下滑动切换不同设备
- 实时查看命令执行状态

## 支持的 AI Agent

| Agent | 模式 | 命令 |
|-------|------|------|
| OpenCode | Session（交互式） | `opencode` |
| Claude Code | Headless（一次性） | `claude` |
| Codex CLI | Headless（一次性） | `codex` |
| Aider | Headless（一次性） | `aider` |

## 系统要求

- **macOS Desktop**: macOS 13.0+
- **iPhone**: iOS 16.0+
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

打开 BrewPing iPhone 应用，点击 `+` 添加设备，或使用"自动发现"找到 Mac。

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

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/status` | 设备状态 |
| GET | `/api/agents` | Agent 列表 |
| POST | `/api/message` | 发送消息 |
| GET | `/api/message/:id` | 查询命令状态 |
| POST | `/api/agents/default` | 设置默认 Agent |
| POST | `/api/agents/:id/switch` | 切换 Agent |
| POST | `/api/session/start` | 启动 Session |
| POST | `/api/session/stop` | 停止 Session |

## 配置

配置文件位于 `~/.brewping/`:

- `device.json` — 设备身份（Device ID、名称）
- `config.json` — Agent 配置（默认 Agent、模型偏好）
- `session.json` — 当前 Session 状态

## License

MIT
