# BrewPing

> English | [简体中文](README.zh-CN.md)

<p align="center">
  <a href="https://www.commitbrew.com">
    <img src="./logo/logo.png" alt="BrewPing" width="120" />
  </a>
</p>

**A local-network remote control for coding agents running on your own computer.**

BrewPing lets you monitor, control, and approve coding-agent tasks running on your own Mac or Windows
computer — from your iPhone, Apple Watch, or Android phone. Pair once over your local network, and the
work stays on your machine: no account, no analytics, no server of ours in the path.

*Your agents, your models, your machine — driven from your phone, on your own network.*

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

## ⬇️ Download

| Platform | Get it |
|---|---|
| **iPhone / Apple Watch** | **Available on the App Store** — search for **BrewPing** |
| **macOS** | [GitHub Release](https://github.com/banmu123/BrewPing/releases/tag/v1.0.0) — signed & notarized DMG · or the [download page](https://www.commitbrew.com/#download) |
| **Windows** | [GitHub Release](https://github.com/banmu123/BrewPing/releases/tag/v1.0.0) — `setup.exe` / `.msi` (Windows 10/11 + WebView2) |
| **Android** | Build from source — `cd Android && ./gradlew assembleDebug` |
| **Source** | `git clone https://github.com/banmu123/BrewPing.git` |

The macOS and Windows builds on the release page are the same code as this repository at tag `v1.0.0`.
Which surfaces are shipped, in-repo-but-unreleased, or not started is spelled out in
[Platform status](#-platform-status) — and nowhere else.

## 📸 Screenshots

<p align="center">
  <img src="docs/screenshots/macos-main-en.png" alt="BrewPing on macOS" width="62%" />
  <img src="docs/screenshots/ios-main.png" alt="BrewPing on iPhone" width="19%" />
</p>
<p align="center">
  <sub><b>macOS desktop</b> &nbsp;·&nbsp; <b>iPhone</b></sub>
</p>

## What BrewPing is — and what it is not

**BrewPing is not a coding agent.** It does not write code, it does not call a model on your behalf,
and it does not replace the tools you already use.

It is a **remote interface for coding agents that are already running on your own computer**. The
agent does the actual work; BrewPing is how you watch it, steer it, and approve what it is about to do
— without sitting at that machine.

```
Coding agent   →  does the actual coding work   (OpenCode / Claude Code / Codex CLI / pi)
BrewPing       →  lets you monitor, control, and approve that work remotely
```

BrewPing ships no agent and no model. It detects the CLI agents you installed, reads the
configuration they already have, and drives them exactly as they are — your subscriptions,
credentials, and settings stay where they are.

## 🎯 Who is it for?

- You run a coding agent — OpenCode, Claude Code, Codex CLI, or pi — on a Mac or Windows machine, and
  you want to kick off work, check progress, or approve a risky command **without sitting at that
  machine**.
- You want that from your **phone or watch**: one hand, one glance, no remote desktop.
- You care that your code, prompts, and agent output **stay on your own machines**.

**Not for you if:** you don't have any of those CLI agents installed (BrewPing drives them, it does
not replace them), or you are looking for a hosted coding agent that runs in the cloud.

## 🤔 Why BrewPing instead of SSH, remote desktop, or a hosted agent?

| | SSH / terminal apps | Remote desktop | Hosted coding agents | **BrewPing** |
|---|---|---|---|---|
| Agent-aware UI (status, transcripts, models) | ✗ | ✗ | ✓ | ✓ |
| Usable on a phone / watch | awkward | screen-shaped | ✓ | ✓ (native apps) |
| Keeps your existing agent config & logins | ✓ | ✓ | ✗ | ✓ (reads them, never replaces them) |
| Approval gate before risky commands run | ✗ | ✗ | varies | ✓ (safe / ask-all / auto) |
| Your code and prompts stay on your machines | ✓ | ✓ | usually not | ✓ (local network only) |
| Works with several agents + model switching | ✗ | ✗ | ✗ | ✓ |

## ✨ Features

- **Remote monitoring** — live agent status and streaming output, rendered as Markdown, on your phone
  or watch.
- **Remote control** — start and stop sessions, send instructions, switch the active agent and model.
- **Approval gate** — dangerous commands are held until you approve them; a pending request times out
  as *denied*, never as approved.
- **Local-first** — commands and output travel only between your phone and the computer you paired.
- **No account, no sign-up** — pairing is a one-time 6-digit code, not a login.
- **Automatic discovery** — Bonjour/mDNS finds computers on the current Wi-Fi; manual host and port is
  always available as a fallback.
- **Four agents, one interface** — OpenCode, Claude Code, Codex CLI, and pi, with per-agent model
  switching ([details](#-supported-coding-agents)).
- **iPhone, Apple Watch, Android** — the Watch app takes voice-dictated instructions and shows the
  reply; the Android app shares the same flow.
- **Conversations and working folders** — conversations are bound to a folder, so file operations
  happen where the conversation lives. Agent, model, and approval level are set **per conversation**.
- **Multi-device** — pair several computers and switch between them from the device bar.
- **Bilingual UI** — English and Simplified Chinese, switchable in-app without a restart.

## 🔄 How it works

```
┌──────────────────────────────────────┐
│          Your Mac / Windows          │
│                                      │
│   Coding agent                       │
│   OpenCode · Claude Code ·           │
│   Codex CLI · pi                     │
│              │                       │
│        BrewPing Desktop              │
└──────────────┼───────────────────────┘
               │   local network
               │   HTTP API + Bonjour/mDNS discovery
        ┌──────┴───────┐
        │              │
     iPhone        Apple Watch
        │              │
   monitor · control · approve
```

1. Your agent runs on your computer, exactly as it does today.
2. BrewPing Desktop sits next to it, exposes a local HTTP API, and supervises the agent process.
3. Your phone or watch discovers the computer on the same network and pairs with a one-time code.
4. From there you monitor, instruct, and approve — the network never leaves your LAN.

## 📦 Platform status

| Platform | Status | Notes |
|---|---|---|
| **iOS** | **Available** — App Store | iPhone only (iOS 17.0+); search for **BrewPing** |
| **watchOS** | **Available** — App Store | Ships with the iPhone app (watchOS 11.6+); voice-dictated instructions, swipe to switch agent/model |
| **macOS** | **Available** — GitHub Release `v1.0.0` | macOS 13.0+; universal binary (Apple Silicon + Intel), Developer ID signed, notarized, stapled |
| **Windows** | **Available** — GitHub Release `v1.0.0` | Windows 10/11 + WebView2; `setup.exe` / `.msi` |
| **Android** | **Built, not published** | Android 8.0+ (`minSdk` 26); builds from this repository, not yet submitted to Google Play |
| **Wear OS** | **In the repository, not released** | `Android/wear` builds and is covered by CI; no device testing, no store submission |
| **Cross-network** | **Not supported** | Local network only — no hosted service and no official public relay |

"Built" means the artifact can be produced from this repository. It does **not** mean it is available
to the public. Anything not listed as *Available* above is not shipped.

## 🧠 Supported coding agents

BrewPing drives CLI agents **you installed yourself**. It never bundles or redistributes them, and it
never replaces their configuration — it reads what is there.

| Agent | Mode | Command | Configuration read from |
|-------|------|---------|-------------------------|
| OpenCode | Session (interactive PTY) | `opencode` | `~/.config/opencode/opencode.json` |
| Claude Code | Headless (one-shot) | `claude` | `~/.claude/settings.json` |
| Codex CLI | Headless (one-shot) | `codex` | `~/.codex/config.toml` |
| pi | Headless (one-shot) | `pi` | `~/.pi/agent/settings.json` + `~/.pi/agent/models.json` |

Install the ones you want to use:

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

Product names and trademarks belong to their respective owners — see [TRADEMARKS.md](TRADEMARKS.md).

## 🚀 Getting started

### 1. Install BrewPing Desktop

- **macOS** — download the DMG from the [GitHub Release](https://github.com/banmu123/BrewPing/releases/tag/v1.0.0)
  (or the [download page](https://www.commitbrew.com/#download)), open it, and drag **BrewPing Desktop**
  into Applications. It is signed, notarized, and stapled, so Gatekeeper opens it without warnings.
- **Windows** — download `setup.exe` or the `.msi` from the same release and install it.
- **From source (macOS)**:

  ```bash
  git clone https://github.com/banmu123/BrewPing.git
  cd BrewPing
  ./build-app.sh                          # produces build/BrewPing Desktop.app
  open "build/BrewPing Desktop.app"
  ```

### 2. Install the phone app

- **iPhone / Apple Watch** — install **BrewPing** from the App Store.
- **Android** — build and install from source:

  ```bash
  cd Android && ./gradlew assembleDebug   # Windows: gradlew.bat assembleDebug
  ```

### 3. Pair your phone

1. In BrewPing Desktop, open **Show Pairing Code** — a 6-digit code and a QR code appear.
2. On your phone, scan the QR code, or tap **Add Device** and type the code.
3. Both devices must be on the **same local network**.

The pairing code is single-use and expires after 10 minutes.

### 4. Point it at an agent

BrewPing lists the agents it found on the computer. Pick one, choose a working folder, and send your
first instruction — you can switch agent and model at any time, per conversation.

Full setup detail, including manual host/port entry when multicast is blocked, is in
[docs/](docs/) and [CONTRIBUTING.md](CONTRIBUTING.md).

### ⌨️ Use BrewPing from the CLI

```bash
swift run BrewPing start                        # start an OpenCode session in a PTY
swift run BrewPing status                       # show the current session status
swift run BrewPing send "Fix the failing test"  # send a message to the session
swift run BrewPing attach                       # attach to the running session (Ctrl+D to detach)
swift run BrewPing stop                         # stop the session
```

## 🔒 Security & privacy

- **Local network only.** No account, no analytics, no third-party SDKs, and no server operated by us
  is in the request path. Commands, agent output, and transcribed speech travel only between your
  phone (or watch) and the computer you paired. Full text: [privacy policy](docs/privacy.html).
- **Pairing, not login.** A one-time 6-digit code (single use, 10-minute expiry) is exchanged for a
  long-lived token. Every `/api/*` request carries `Authorization: Bearer <token>`; writes also carry
  `X-BrewPing-Timestamp` and `X-BrewPing-Nonce`, giving a 120-second replay-protected window.
- **The token is equivalent to command execution on that machine.** It is stored with `0600`
  permissions on the desktop (`~/.brewping/pairing.json`) and in the iPhone Keychain.
- **The approval gate is a safety net, not a sandbox.** It intercepts commands at the point they enter
  the agent. A shell command the agent spawns on its own is *not* covered. Treat it as a guard for
  **your** instructions, not as isolation for the agent.
- **Cross-network access is your own call.** BrewPing does not operate, configure, or endorse a relay;
  if you need it, that is a network problem you solve on your side (for example with a VPN overlay such
  as Tailscale or WireGuard).

Local state lives in `~/.brewping/`: `device.json` (identity), `pairing.json` (token, `0600`),
`approval.json` (approval mode and always-allow rules, `0600`), `config.json` (agent and model
preferences), `session.json` (current session).

See [SECURITY.md](SECURITY.md) for the full security model and what is explicitly out of scope.

## 🏗️ Architecture

- **Desktop service** — a Swift core (`Sources/App`, `Sources/Agents`, `Sources/PTY`,
  `Sources/Session`, `Sources/Protocol`, Swift 5.9 / SwiftPM, no third-party Swift dependencies). It
  exposes an HTTP API on your LAN, supervises agent processes, and gates commands through the approval
  check. The Windows build reimplements the same API surface in Rust (Tauri 2 + axum + React) and is
  covered by the same clients.
- **Clients** — iOS and watchOS (SwiftUI + WatchConnectivity), Android (Kotlin + Jetpack Compose), and
  a CLI (`swift run BrewPing …`). Clients never talk to each other, and never to a machine you did not
  pair.
- **Discovery** — Bonjour/mDNS on the local network, with manual host and port as a fallback.
- **Transport & auth** — HTTP on the LAN; a bearer token on every call, plus timestamp and nonce on
  writes.
- **Run status** — the desktop derives the authoritative execution phase for a command
  (`queued` / `thinking` / `streaming` / `stalled` / `completed` / `failed`) and serves it through the
  API. Clients display it; they never guess whether a run is stuck.
- **HTTP API** — `POST /api/pair` and `GET /api/status` are public; everything else needs the bearer
  token. Endpoints cover agents (`/api/agents…`), messages and run status (`/api/message…`), sessions
  (`/api/session…`), approvals (`/api/approvals…`), conversations (`/api/conversations…`), and
  folders (`/api/folders…`).

```
Sources/
├── App/                  # HTTP API, routing, pairing store, approval gate, conversations
├── Agents/               # agent discovery + OpenCode / Claude Code / Codex / pi drivers
├── PTY/                  # pseudo-terminal handling for interactive agents
├── Session/              # session lifecycle
├── Protocol/             # wire protocol shared by every client
├── BrewPing/             # CLI entry point (start / status / send / attach / stop)
├── BrewPingDesktop/      # macOS SwiftUI app (window + menu bar)
└── BrewPingwinDesktop/   # Windows desktop (Tauri 2 + axum + React)
ios/                      # iPhone app + Apple Watch app
Android/                  # Android phone app + Wear OS module
Scripts/                  # packaging (build-mac-app.sh) + entitlement/Info.plist for the DMG
docs/                     # design notes + privacy policy
```

## 📚 Documentation

- **[Privacy policy](docs/privacy.html)** — what BrewPing does and does not touch
- **[Project status](docs/PROJECT_STATUS.md)** — platforms, test counts, maintenance process, known limitations
- **[iOS structure & modules](docs/BrewPing-iOS端结构与模块划分.md)** — iPhone app layout and state flow
- **[Windows multi-conversation design](docs/BrewPing-Windows端多对话管理实现方案.md)** — desktop conversation model
- **[Provider management](docs/BrewPing-Provider管理-Lody新建Provider迁移方案.md)** — provider config internals
- **[Folder browsing](docs/BrewPing-获取文件夹-Windows落地方案.md)** — working-folder binding
- **[Trademarks](TRADEMARKS.md)** — third-party names used to describe compatibility

## 🤝 Contributing & development

Issues and pull requests are welcome. Build commands, CI expectations, and repository conventions live
in **[CONTRIBUTING.md](CONTRIBUTING.md)**; security reports go through **[SECURITY.md](SECURITY.md)**.

Sanity check before opening a PR — every suite runs without a device or emulator:

```bash
swift test --disable-sandbox                       # 66 Swift tests (macOS)
cargo test --locked                                # 318 Rust tests (Sources/BrewPingwinDesktop/src-tauri)
cd Android && ./gradlew test                       # 109 Android tests (:core + :app)
```

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs all of the above plus an iOS + watchOS
compile and repository-hygiene checks on every push and pull request, with a nightly schedule to catch
runner toolchain drift.

## 🗺️ Roadmap

Direction, not commitments — nothing here is shipped yet:

- **More agent integrations.** The agent catalog is built to be extended beyond the four supported today.
- **Wear OS client.** The module is in the repository and builds in CI, but it is not released and has
  not been through device testing or store submission.
- **Smoother multi-device workflows.** Pairing several computers works today; per-device context and
  faster switching are the next step.

**Not planned:** a hosted service or an official public relay. Cross-network access stays a user-side
network setup.

## ⚠️ Trademarks

OpenCode, Claude, Claude Code, Codex, and pi are trademarks of their respective owners. BrewPing is
not affiliated with, endorsed by, or sponsored by them; these names appear only to describe
compatibility — see **[TRADEMARKS.md](TRADEMARKS.md)** for the per-name list.

## 📄 License

[MIT](LICENSE).

BrewPing does not bundle or redistribute any third-party agent. It only detects and runs the
command-line tools you have already installed on your own computer.

## 🙏 Credits

- [Swift](https://www.swift.org/) + SwiftUI / AppKit — the core service and the macOS app
- [Tauri](https://tauri.app/) — the Windows desktop shell
- [Jetpack Compose](https://developer.android.com/jetpack/compose) — the Android app
- [shields.io](https://shields.io/) — README badges
- OpenCode, Claude Code, Codex CLI and pi — the agents BrewPing drives (unofficial, see Trademarks)
