# BrewPing

> [English](README.md) | 简体中文

<p align="center">
  <a href="https://www.commitbrew.com">
    <img src="./logo/logo.png" alt="BrewPing" width="120" />
  </a>
</p>

**用手机远程指挥你自己电脑上的编程 Agent。**

BrewPing 让你在自己的 Mac 或 Windows 上监控、操作并审批正在运行的编程 Agent —— 用 iPhone、Apple Watch 或 Android 手机完成。在局域网里配对一次，代码和提示词始终留在你自己的机器上：没有账号、没有 analytics，链路上也没有我们自己的服务器。

*你的 Agent、你的模型、你的电脑 —— 在同一个局域网里，用手机发指令。*

<div align="center">

[![CI](https://github.com/banmu123/BrewPing/actions/workflows/ci.yml/badge.svg)](https://github.com/banmu123/BrewPing/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/banmu123/BrewPing?style=social)](https://github.com/banmu123/BrewPing/stargazers)
![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=F0F0F0)
![iOS](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=F0F0F0)
![watchOS](https://img.shields.io/badge/watchOS-11.6%2B-000000?logo=apple&logoColor=F0F0F0)
![Android](https://img.shields.io/badge/Android-8%2B-3DDC84?logo=android&logoColor=white)
![Swift tests](https://img.shields.io/badge/swift%20tests-66%20passing-brightgreen)

</div>

## ⬇️ 下载

| 端 | 获取方式 |
|---|---|
| **iPhone / Apple Watch** | **已在 App Store 上架** —— 搜索 **BrewPing** |
| **macOS** | [GitHub Release](https://github.com/banmu123/BrewPing/releases/tag/v1.0.0) —— 已签名并公证的 DMG · 或走[官网下载页](https://www.commitbrew.com/#download) |
| **Windows** | [GitHub Release](https://github.com/banmu123/BrewPing/releases/tag/v1.0.0) —— `setup.exe` / `.msi`（Windows 10/11 + WebView2） |
| **Android** | 源码构建 —— `cd Android && ./gradlew assembleDebug` |
| **源码** | `git clone https://github.com/banmu123/BrewPing.git` |

Release 页上的 macOS / Windows 安装包与本仓库 `v1.0.0` tag 的代码一致。哪些端已发布、哪些只在仓库里、哪些还没开始，只写在[平台状态](#-平台状态)一处。

## 📸 截图

<p align="center">
  <img src="docs/screenshots/macos-main-en.png" alt="BrewPing macOS 桌面端" width="62%" />
  <img src="docs/screenshots/ios-main.png" alt="BrewPing iPhone" width="19%" />
</p>
<p align="center">
  <sub><b>macOS 桌面端</b> &nbsp;·&nbsp; <b>iPhone</b></sub>
</p>

## BrewPing 是什么，不是什么

**BrewPing 不是编程 Agent。** 它不写代码、不替你调用模型，也不替代你已经在用的工具。

它是**给「已经运行在你自己电脑上」的编程 Agent 用的远程界面**。真正干活的是 Agent；BrewPing 让你不必守在那台机器前，也能看到它在做什么、指挥它、并在它动手之前批准或拒绝。

```
编程 Agent   →  真正干活的部分      （OpenCode / Claude Code / Codex CLI / pi）
BrewPing     →  让你远程监控、操作、审批这些工作
```

BrewPing 不带 Agent、不带模型。它发现你装好的 CLI Agent，读取它们已有的配置，按原样驱动 —— 你的订阅、凭据、设置全部留在原处。

## 🎯 适合谁用

- 你在 Mac 或 Windows 上跑 OpenCode / Claude Code / Codex CLI / pi，希望**离开那张桌子**也能让它开工、看进度、或在危险命令执行前拍板；
- 你希望用**手机或手表**完成这些：一只手、看一眼，不用开远程桌面；
- 你在意代码、提示词、Agent 输出**只留在自己的机器上**。

**不适合**：还没装上述 CLI Agent（BrewPing 是驱动它们，不是替代它们）；或者你想要的是跑在云端的托管式编程 Agent。

## 🤔 为什么用 BrewPing，而不是 SSH、远程桌面或云端 Agent？

| | SSH / 终端类 App | 远程桌面 | 云端 Agent | **BrewPing** |
|---|---|---|---|---|
| 懂 Agent 的界面（状态 / 转录 / 模型） | ✗ | ✗ | ✓ | ✓ |
| 手机 / 手表上好用 | 别扭 | 按屏幕缩放 | ✓ | ✓（原生 App） |
| 沿用你现有的 Agent 配置与登录 | ✓ | ✓ | ✗ | ✓（只读取，不替换） |
| 危险命令执行前有审批闸门 | ✗ | ✗ | 视产品而定 | ✓（safe / askAll / auto） |
| 代码与提示词留在自己机器 | ✓ | ✓ | 通常不行 | ✓（仅局域网） |
| 多 Agent + 模型远程切换 | ✗ | ✗ | ✗ | ✓ |

## ✨ 功能

- **远程监控** —— 手机上实时看到 Agent 状态与流式输出，按 Markdown 渲染。
- **远程操作** —— 启停会话、发指令、切换当前 Agent 与模型。
- **审批闸门** —— 危险命令会挂起等你确认；挂起的请求**超时即视为拒绝**，沉默永远不等于同意。
- **本地优先** —— 指令与输出只在你手机和你配对过的那台电脑之间流动。
- **不需要账号** —— 配对是一次性的 6 位码，不是登录。
- **自动发现** —— Bonjour/mDNS 找到同一 Wi-Fi 下的电脑；手动填 host 与 port 永远可用作兜底。
- **四个 Agent，一套界面** —— OpenCode、Claude Code、Codex CLI、pi，并支持按 Agent 切换模型（[详见](#-支持的-agent)）。
- **iPhone / Apple Watch / Android** —— 手表支持语音口述指令并直接看回复；Android 端流程与 iPhone 一致。
- **对话与工作目录绑定** —— 对话按绑定目录组织，文件操作就发生在对话所在的目录；Agent、模型、授权档位都是**对话级**设置。
- **多设备** —— 配对多台电脑，在设备栏里直接切换。
- **双语界面** —— 英文 / 简体中文，应用内切换即时生效。

## 🔄 工作原理

```
┌──────────────────────────────────────┐
│          你的 Mac / Windows          │
│                                      │
│   编程 Agent                         │
│   OpenCode · Claude Code ·           │
│   Codex CLI · pi                     │
│              │                       │
│        BrewPing Desktop              │
└──────────────┼───────────────────────┘
               │   本地网络
               │   HTTP API + Bonjour/mDNS 发现
        ┌──────┴───────┐
        │              │
     iPhone        Apple Watch
        │              │
    监控 · 操作 · 审批
```

1. Agent 照旧运行在你自己电脑上。
2. BrewPing Desktop 跑在它旁边，对外提供局域网 HTTP API，并托管 Agent 进程。
3. 手机或手表在同一网络内发现这台电脑，用一次性配对码完成配对。
4. 之后就能监控、下指令、审批 —— 全程不出局域网。

## 📦 平台状态

| 平台 | 状态 | 说明 |
|---|---|---|
| **iOS** | **已上架** —— App Store | 仅 iPhone（iOS 17.0+）；搜索 **BrewPing** |
| **watchOS** | **已上架** —— App Store | 随 iPhone App 一起发布（watchOS 11.6+）；支持语音口述指令、滑动切换 Agent 与模型 |
| **macOS** | **已发布** —— GitHub Release `v1.0.0` | macOS 13.0+；universal 二进制（Apple Silicon + Intel），Developer ID 签名、公证、staple |
| **Windows** | **已发布** —— GitHub Release `v1.0.0` | Windows 10/11 + WebView2；`setup.exe` / `.msi` |
| **Android** | **已构建，未发布** | Android 8.0+（`minSdk` 26）；可从本仓库构建，尚未提交 Google Play |
| **Wear OS** | **已在仓库内，未发布** | `Android/wear` 可构建并已进 CI；未过真机测试、未提交商店 |
| **跨网络访问** | **不支持** | 仅局域网 —— 没有托管服务，也没有官方公网中继 |

「已构建」只表示这个产物能从本仓库产出，**不表示**公众可以获取。上表未标为「已发布 / 已上架」的端，都没有对外发布。

## 🧠 支持的 Agent

BrewPing 驱动的是**你自己装好**的 CLI Agent，从不打包或再分发它们，也不替换它们的配置 —— 只读取现状。

| Agent | 模式 | 命令 | 读取的配置 |
|-------|------|------|-----------|
| OpenCode | 会话（交互式 PTY） | `opencode` | `~/.config/opencode/opencode.json` |
| Claude Code | 无头（一次性） | `claude` | `~/.claude/settings.json` |
| Codex CLI | 无头（一次性） | `codex` | `~/.codex/config.toml` |
| pi | 无头（一次性） | `pi` | `~/.pi/agent/settings.json` + `~/.pi/agent/models.json` |

按需安装：

```bash
# OpenCode
curl -fsSL https://get.opencode.ai | sh

# Claude Code
npm install -g @anthropic-ai/claude-code

# Codex CLI
npm install -g @openai/codex

# pi
npm install -g @earendil-works/pi-coding-agent
```

产品名称与商标归各自所有者，见 [TRADEMARKS.md](TRADEMARKS.md)。

## 🚀 快速开始

### 1. 安装 BrewPing Desktop

- **macOS** —— 从 [GitHub Release](https://github.com/banmu123/BrewPing/releases/tag/v1.0.0)（或[官网下载页](https://www.commitbrew.com/#download)）下载 DMG，打开后把 **BrewPing Desktop** 拖进应用程序。已签名、公证并 staple，双击即开，不会有 Gatekeeper 提示。
- **Windows** —— 从同一个 Release 下载 `setup.exe` 或 `.msi` 安装。
- **源码构建（macOS）**：

  ```bash
  git clone https://github.com/banmu123/BrewPing.git
  cd BrewPing
  ./build-app.sh                          # 产出 build/BrewPing Desktop.app
  open "build/BrewPing Desktop.app"
  ```

### 2. 安装手机端

- **iPhone / Apple Watch** —— 从 App Store 安装 **BrewPing**。
- **Android** —— 源码构建并安装：

  ```bash
  cd Android && ./gradlew assembleDebug   # Windows: gradlew.bat assembleDebug
  ```

### 3. 配对手机

1. 桌面端菜单栏点 **Show Pairing Code**，出现 6 位配对码与二维码；
2. 手机扫码，或点 **Add Device** 手动输入配对码；
3. 两端必须处于**同一个局域网**。

配对码一次性有效、10 分钟过期。

### 4. 接上你的 Agent

BrewPing 会列出电脑上发现的 Agent。选一个、挑好工作目录，发出第一条指令即可 —— 之后随时可以按对话切换 Agent 与模型。

完整配置说明（包括多播被拦时如何手动填 host:port）见 [docs/](docs/) 与 [CONTRIBUTING.md](CONTRIBUTING.md)。

### ⌨️ 从命令行使用

```bash
swift run BrewPing start                        # 在 PTY 里启动一个 OpenCode 会话
swift run BrewPing status                       # 查看当前会话状态
swift run BrewPing send "修一下失败的测试"        # 给会话发一条消息
swift run BrewPing attach                       # 接入正在运行的会话（Ctrl+D 断开）
swift run BrewPing stop                         # 结束会话
```

## 🔒 安全与隐私

- **只在局域网内。** 没有账号、没有 analytics、没有第三方 SDK，链路上也没有我们运营的服务器。你发的指令、Agent 返回的输出、以及被转写的语音，只在你的手机（或手表）与你配对的那台电脑之间流动。完整说明见[隐私政策](docs/privacy.html)。
- **配对，而不是登录。** 一次性 6 位配对码（单次有效、10 分钟过期）换一个长期 token。所有 `/api/*` 请求带 `Authorization: Bearer <token>`；写操作额外带 `X-BrewPing-Timestamp` 与 `X-BrewPing-Nonce`，构成 120 秒防重放窗口。
- **这个 token 等价于在那台机器上执行命令。** 桌面端以 `0600` 权限存在 `~/.brewping/pairing.json`，iOS 端存在 Keychain。
- **审批闸门是安全网，不是沙箱。** 它在命令**进入 Agent 之前**拦截；Agent 自己后续派生的 shell 命令不在覆盖范围内。请把它当作针对**你的指令**的护栏，而不是给 Agent 用的隔离。
- **跨网络访问由你自己决定。** BrewPing 不运营、不配置、也不背书任何中继；若你需要，那是你自己那一侧的网络问题（比如用 Tailscale、WireGuard 这类 VPN 组网解决）。

本地状态都在 `~/.brewping/`：`device.json`（设备身份）、`pairing.json`（token，`0600`）、`approval.json`（授权档位与 always-allow 规则，`0600`）、`config.json`（Agent 与模型偏好）、`session.json`（当前会话）。

完整安全模型与明确的「不在范围内」清单见 [SECURITY.md](SECURITY.md)。

## 🏗️ 架构

- **桌面服务** —— Swift 核心（`Sources/App`、`Sources/Agents`、`Sources/PTY`、`Sources/Session`、`Sources/Protocol`；Swift 5.9 / SwiftPM，**零第三方 Swift 依赖**）。它在局域网内提供 HTTP API、托管 Agent 进程、并在命令进入 Agent 前做审批检查。Windows 端用 Rust（Tauri 2 + axum + React）实现同一套接口，客户端完全共用。
- **客户端** —— iOS / watchOS（SwiftUI + WatchConnectivity）、Android（Kotlin + Jetpack Compose），以及 CLI（`swift run BrewPing …`）。客户端之间不互相通信，也不会连你没配对过的机器。
- **发现** —— 局域网内 Bonjour/mDNS，手动填 host 与 port 作为兜底。
- **传输与鉴权** —— 局域网 HTTP；每次调用带 bearer token，写操作另加时间戳与 nonce。
- **执行状态** —— 桌面端推导命令的权威执行阶段（`queued` / `thinking` / `streaming` / `stalled` / `completed` / `failed`）并通过 API 提供。客户端只负责展示，绝不自己猜「是不是卡住了」。
- **HTTP API** —— `POST /api/pair` 与 `GET /api/status` 公开，其余都需要 bearer token。接口覆盖 Agent（`/api/agents…`）、消息与执行状态（`/api/message…`）、会话（`/api/session…`）、审批（`/api/approvals…`）、对话（`/api/conversations…`）与目录（`/api/folders…`）。

```
Sources/
├── App/                  # HTTP API、路由、配对存储、审批闸门、对话
├── Agents/               # Agent 发现 + OpenCode / Claude Code / Codex / pi 驱动
├── PTY/                  # 交互式 Agent 的伪终端处理
├── Session/              # 会话生命周期
├── Protocol/             # 各端共用的通信协议
├── BrewPing/             # CLI 入口（start / status / send / attach / stop）
├── BrewPingDesktop/      # macOS SwiftUI App（窗口 + 菜单栏）
└── BrewPingwinDesktop/   # Windows 桌面端（Tauri 2 + axum + React）
ios/                      # iPhone App + Apple Watch App
Android/                  # Android 手机端 + Wear OS 模块
Scripts/                  # 打包脚本（build-mac-app.sh）+ DMG 用 entitlements/Info.plist
docs/                     # 设计文档 + 隐私政策
```

## 📚 文档

- **[隐私政策](docs/privacy.html)** —— BrewPing 碰什么、不碰什么
- **[项目状态](docs/PROJECT_STATUS.md)** —— 平台、测试数量、维护流程与已知限制
- **[iOS 端结构与模块划分](docs/BrewPing-iOS端结构与模块划分.md)** —— iPhone 端布局与状态流
- **[Windows 端多对话管理实现方案](docs/BrewPing-Windows端多对话管理实现方案.md)** —— 桌面端对话模型
- **[Provider 管理](docs/BrewPing-Provider管理-Lody新建Provider迁移方案.md)** —— 配置内部实现
- **[获取文件夹落地方案](docs/BrewPing-获取文件夹-Windows落地方案.md)** —— 工作目录绑定
- **[商标](TRADEMARKS.md)** —— 仅用于说明兼容性的第三方名称

## 🤝 参与贡献与开发

欢迎提 issue 与 PR。构建命令、CI 会跑什么、以及仓库约定见 **[CONTRIBUTING.md](CONTRIBUTING.md)**；安全问题请走 **[SECURITY.md](SECURITY.md)**。

提 PR 前的自检 —— 所有测试都不需要设备或模拟器：

```bash
swift test --disable-sandbox                       # Swift 66 个用例（macOS）
cargo test --locked                                # Rust 318 个用例（Sources/BrewPingwinDesktop/src-tauri）
cd Android && ./gradlew test                       # Android 109 个用例（:core + :app）
```

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在每次 push / PR 上运行上述全部内容，另加 iOS + watchOS 编译与仓库卫生检查；还有每日定时运行以捕捉 runner 工具链漂移。

## 🗺️ 路线图

方向而已，不是承诺 —— 以下都**尚未发布**：

- **接入更多 Agent。** Agent 目录本来就是为了扩展而设计的，当前支持四个。
- **Wear OS 客户端。** 模块已在仓库内并进了 CI，但尚未发布，也未过真机测试与商店提交。
- **更顺的多设备体验。** 多台电脑配对已经可用；下一步是每设备上下文与更快的切换。

**不做**：托管服务与官方公网中继。跨网络访问仍由用户自己那一侧的网络方案解决。

## ⚠️ 商标声明

OpenCode、Claude、Claude Code、Codex、pi 等名称归各自所有者所有。BrewPing 与这些厂商**没有任何隶属、赞助或背书关系**；提及这些名称仅用于说明兼容性，逐个名称的说明见 **[TRADEMARKS.md](TRADEMARKS.md)**。

## 📄 许可证

[MIT](LICENSE)。

BrewPing 不打包、不再分发任何第三方 Agent，只检测并调用你本机已安装的命令行工具。

## 🙏 致谢

- [Swift](https://www.swift.org/) + SwiftUI / AppKit —— 核心服务与 macOS 端
- [Tauri](https://tauri.app/) —— Windows 桌面端外壳
- [Jetpack Compose](https://developer.android.com/jetpack/compose) —— Android 端
- [shields.io](https://shields.io/) —— README 徽章
- OpenCode、Claude Code、Codex CLI、pi —— BrewPing 驱动的 Agent（非官方，见商标声明）
