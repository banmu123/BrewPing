<p align="center">
    <a href="https://www.commitbrew.com/#download">
        <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=F0F0F0"/>
    </a>
    <a href="https://www.commitbrew.com/#download">
        <img src="https://custom-icon-badges.demolab.com/badge/Windows-0078D6?logo=windows11&logoColor=white"/>
    </a>
    <a href="https://www.commitbrew.com/#download">
        <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=F0F0F0"/>
    </a>
    <a href="https://www.commitbrew.com/#download">
        <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white"/>
    </a>
</p>

<p align="center">
  <a href="https://www.commitbrew.com">
    <picture>
      <img src="./logo/logo.png" width="128"/>
    </picture>
  </a>
</p>
<h1 align="center">
<a href="https://www.commitbrew.com" alt="brewping-site">BrewPing</a>
</h1>
<p align="center">
  <a href="./README.md">English</a> | <b>简体中文</b>
</p>
<p align="center">
  <b>一个遥控器，用来指挥运行在你自己电脑上的编程 Agent。</b>
</p>
<p align="center">
  BrewPing 在你的 Mac 或 Windows 上运行一个轻量桌面服务，驱动已经装好的命令行 Agent。手机在同一局域网内完成配对，之后就可以从 iPhone、Apple Watch 或 Android 发送指令、跟踪进度，并对危险命令进行确认。
</p>
<p align="center">
  <a href="https://www.commitbrew.com/#download">
    <b>下载</b>
  </a>
  |
  <a href="./docs/BrewPing-iOS端结构与模块划分.md">
    <b>文档</b>
  </a>
  |
  <a href="./docs/privacy.html">
    <b>隐私政策</b>
  </a>
</p>
<p align="center">
  <a aria-label="Website" href="https://www.commitbrew.com" target="_blank">
    <img alt="" src="https://img.shields.io/badge/Website-000000?style=for-the-badge&logo=google-chrome&logoColor=white">
  </a>
  <a aria-label="License" href="#license">
    <img alt="" src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge">
  </a>
</p>

<p align="center">
  <img src="./logo/AppIcon-1024.png" alt="BrewPing 应用图标" width="160" />
</p>

```
┌──────────────┐    HTTP API     ┌─────────────────────────┐
│    手机       │ ◄────────────►  │   BrewPing Desktop      │
│ iOS / Android│   同一局域网     │  macOS 菜单栏 + 窗口     │
└──────┬───────┘   Bonjour       │  或 Windows（Tauri）     │
       │            自动发现     └───────────┬─────────────┘
       │ WatchConnectivity                   │ PTY / CLI
┌──────┴───────┐                  ┌──────────┴─────────────┐
│ Apple Watch  │                  │  opencode · claude     │
│  (watchOS)   │                  │  codex · aider         │
└──────────────┘                  └────────────────────────┘
```

## 你可以用 BrewPing 做什么

### 在家里任何位置发一条指令

启动桌面服务、配对一次，就可以用手机发送指令。命令执行期间 BrewPing 会显示 Agent 的运行状态，执行结束后返回结果——你不必守在键盘前。

### 继续使用你已经配置好的 Agent 和模型

BrewPing 不替代你的 Agent，也不接管它们的登录状态。它会发现电脑里已安装的命令行 Agent，读取各自配置的模型，并允许你远程切换当前 Agent 或模型。订阅、凭据和权限配置都保持原样。

### 危险命令执行前先经过你确认

命令在进入 Agent 之前会被检查。BrewPing 会识别危险操作（`rm -rf`、`git reset --hard`、`curl | sh` 等）并挂起等待你确认。三档可选：只拦截危险命令、每条命令都确认、或全部免确认。挂起的请求超时即视为拒绝——沉默不等于放行。

## 连接一台电脑

在负责干活的机器上运行桌面服务：

```bash
# macOS
./build-app.sh
open "build/BrewPing Desktop.app"
```

```bash
# Windows
cd Sources/BrewPingwinDesktop
npm install
npm run tauri dev
```

然后配对手机：

1. 在 BrewPing Desktop 里打开 **Show Pairing Code**，会显示 6 位配对码（同时显示二维码）；
2. 用手机扫描二维码，或点 **Add Device** 手动输入配对码；
3. 两台设备必须处于**同一局域网**。BrewPing 不提供公网中继，也不会连接你没有配置过的设备。

配对码只交换一次，用于换取长期 token。iOS 端 token 存放在 Keychain，桌面端存放在 `~/.brewping/pairing.json`（权限 `0600`）。此后所有 `/api/*` 请求都带 `Authorization: Bearer <token>`；写操作还要带 `X-BrewPing-Timestamp` 与 `X-BrewPing-Nonce`（120 秒时间窗，防重放）。

## 通过 CLI 使用 BrewPing

桌面服务自带的 CLI 也可以从终端或脚本驱动会话：

```bash
swift run BrewPing start                        # 在 PTY 中启动 OpenCode 会话
swift run BrewPing status                       # 查看当前会话状态
swift run BrewPing send "修复失败的测试"         # 向会话发送一条消息
swift run BrewPing attach                       # 附着到运行中的会话（Ctrl+D 退出）
swift run BrewPing stop                         # 停止会话
```

## 从 iPhone、Apple Watch 和 Android 控制 Agent

### iPhone 与 Android

两个 App 使用同一套流程：在当前 Wi-Fi 下发现电脑，或用主机名和端口手动添加；通过扫码或输入 6 位配对码完成配对；之后浏览对话、发送指令、切换 Agent 与模型，并对命令进行授权确认。

### Apple Watch

Watch App 可以发送语音转写的指令，用滑动切换 Agent 与模型，并实时跟踪当前命令的执行状态。

### 手边没有电脑？

iOS 端可以添加一个**演示设备**，在本地模拟设备发现、Agent、会话与命令结果——无需任何硬件即可走通完整流程。

## 让对话与它的工作目录保持一致

### 按工作目录分组的对话

手机端展示从桌面端同步过来的对话，并按各自绑定的工作目录分组。对话可以置顶、归档和重新打开，历史始终跟随对话本身。

### 为对话绑定工作目录

在支持文件夹浏览的桌面端上，可以为对话绑定工作目录，让文件操作作用在对话所在的位置。未绑定时回退到 Agent 的默认目录。

### 对话级的 Agent、模型与授权

Agent、模型和授权档位都是**对话级**设置：切换 Agent 会清除该对话的模型选择；每个对话可以使用自己的模型，互不影响。

## 更多内置能力

- **多设备** — 同时管理多台电脑（macOS、Windows、Linux），在设备栏里随时切换。
- **Bonjour/mDNS 自动发现** — 在当前 Wi-Fi 下找到电脑，无需手输 IP。
- **模型切换** — 列出每个 Agent 已配置的模型并远程切换，立即生效。
- **授权模式** — 安全（默认）、每次确认、自动三档，支持全局或按对话设置。
- **Markdown 记录** — Agent 输出以 Markdown 渲染，长回复也便于阅读。
- **仅限局域网** — 没有账号、没有数据分析、没有第三方 SDK；指令与输出只在你的手机和自己的电脑之间传输。
- **应用内切换语言** — 简体中文与英文，App 内切换即时生效，无需重启。

## 支持的 Agent

BrewPing 驱动的是你电脑上已安装的命令行 Agent。产品名称与商标归各自所有者所有（见[商标声明](#商标声明)）。

| Agent | 模式 | 命令 | 读取的配置 |
|-------|------|------|-----------|
| OpenCode | 会话（交互式 PTY） | `opencode` | `~/.config/opencode/opencode.json` |
| Claude Code | Headless（一次性） | `claude` | `~/.claude/settings.json` |
| Codex CLI | Headless（一次性） | `codex` | `~/.codex/config.toml` |
| Aider | Headless（一次性） | `aider` | Aider 配置 |

按需安装：

```bash
# OpenCode
curl -fsSL https://get.opencode.ai | sh

# Claude Code
npm install -g @anthropic-ai/claude-code

# Codex CLI
npm install -g @openai/codex

# Aider
python3 -m pip install -U aider-install && aider-install
```

## HTTP API

除 `POST /api/pair` 与 `GET /api/status` 外，所有接口都要求 `Authorization: Bearer <token>`；写接口还需携带 `X-BrewPing-Timestamp` 与 `X-BrewPing-Nonce`。

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/pair` | 用 6 位配对码换取长期 token（公开） |
| GET | `/api/status` | 设备状态，只读健康检查（公开） |
| GET | `/api/protocol/state` | 协议状态快照 |
| GET | `/api/agents` | 已安装的 Agent 列表 |
| POST | `/api/agents/default` | 设置默认 Agent |
| POST | `/api/agents/:id/switch` | 切换当前 Agent |
| GET | `/api/agents/:id/models` | 该 Agent 已配置的模型（Provider → Models） |
| POST | `/api/agents/models/default` | 设置默认模型 |
| POST | `/api/message` | 发送消息 |
| GET | `/api/message` | 消息列表 |
| GET | `/api/message/:id` | 查询单条命令状态 |
| POST | `/api/session/start` | 启动会话 |
| POST | `/api/session/stop` | 停止会话 |
| GET / POST | `/api/approvals/mode` | 读取或修改授权模式 |
| GET | `/api/approvals` | 待确认的授权请求 |
| POST | `/api/approvals/:id` | `approve` / `deny` / `always_approve` |
| GET / POST | `/api/conversations` | 列出或创建对话 |
| GET / PATCH / DELETE | `/api/conversations/:id` | 读取、更新或删除单个对话 |
| POST | `/api/conversations/:id/activate` | 激活对话 |
| POST | `/api/discovery/refresh` | 刷新局域网发现 |

## 配置

BrewPing 的状态存放在 `~/.brewping/`：

- `device.json` — 设备身份（Device ID、名称）
- `pairing.json` — 配对 token 与临时配对码（权限 `0600`）
- `approval.json` — 全局授权模式与 always-allow 规则（权限 `0600`）
- `config.json` — Agent 配置（默认 Agent、模型偏好）
- `session.json` — 当前会话状态

## 系统要求

- **macOS 桌面端**：macOS 13.0+
- **Windows 桌面端**：安装了 WebView2 的 Windows（Tauri 2）
- **iPhone**：iOS 17.0+
- **Apple Watch**：watchOS 9.0+（需与 iPhone App 配对）
- **Android**：Android 8.0+（minSdk 26）
- 手机与电脑需处于**同一局域网**

## 不止于局域网

局域网配对是 BrewPing 的起点，而不是终点。

`relay-server/` 下有一个 TypeScript 中继服务，但**尚未接入任何客户端**。在接入之前，BrewPing 保持明确的本地属性：没有账号、没有数据分析、没有第三方 SDK，流量不会离开你自己的网络。指令、Agent 输出和语音音频只保留在你的手机与自己的电脑上。

授权拦截也是有边界的：它只拦截"命令进入 Agent 之前"这一处，Agent 中途自行发起的 shell 命令不在本版本的覆盖范围内。

## 从源码构建

```bash
# macOS 桌面端（产出 build/BrewPing Desktop.app）
./build-app.sh

# Windows 桌面端（Tauri 2 + axum）
cd Sources/BrewPingwinDesktop && npm install && npm run tauri dev

# Android
cd Android && ./gradlew assembleDebug        # Windows：gradlew.bat assembleDebug

# iOS / watchOS
open ios/BrewPing.xcodeproj
```

## 仓库结构

- `Sources/App` — 桌面端核心：HTTP API、路由、配对存储、授权拦截
- `Sources/Agents` — Agent 发现、管理与各 CLI Agent 实现
- `Sources/PTY` — 交互式 Agent 的伪终端处理
- `Sources/Session` — 会话生命周期
- `Sources/Protocol` — 各端共用的通信协议
- `Sources/BrewPingDesktop` — macOS SwiftUI 应用（窗口 + 菜单栏）
- `Sources/BrewPingwinDesktop` — Windows 桌面应用（Tauri 2 + axum + React）
- `Sources/BrewPing` — CLI 入口
- `ios/BrewPing` — iPhone 应用
- `ios/Watch` — Apple Watch 应用
- `Android` — Android 应用（Jetpack Compose）
- `relay-server` — TypeScript 中继（尚未接入）
- `docs` — 设计与实现说明
- `logo` — 应用图标与 Logo

## 商标声明

OpenCode、Claude、Claude Code、Codex、Aider 等名称是其各自所有者的商标。BrewPing 与这些厂商**没有任何隶属、赞助或背书关系**；文中提及这些名称仅用于说明兼容性。

BrewPing 只连接**你自己配置**的、位于同一局域网的设备，不会连接第三方设备，也不提供公网中继。

## License

MIT
