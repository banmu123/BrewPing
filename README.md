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
  <b>English</b> | <a href="./README.zh-CN.md">简体中文</a>
</p>
<p align="center">
  <b>A remote control for the coding agents running on your own computer.</b>
</p>
<p align="center">
  BrewPing runs a small desktop service on your Mac or Windows machine and drives the CLI agents already installed there. Pair your phone over the local network, then send instructions, follow progress, and approve risky commands from iPhone, Apple Watch, or Android.
</p>
<p align="center">
  <a href="https://www.commitbrew.com/#download">
    <b>Download</b>
  </a>
  |
  <a href="./docs/BrewPing-iOS端结构与模块划分.md">
    <b>Documentation</b>
  </a>
  |
  <a href="./docs/privacy.html">
    <b>Privacy</b>
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
  <img src="./logo/AppIcon-1024.png" alt="BrewPing app icon" width="160" />
</p>

```
┌──────────────┐    HTTP API     ┌─────────────────────────┐
│    Phone     │ ◄────────────►  │   BrewPing Desktop      │
│ iOS / Android│   same Wi-Fi    │  macOS menu bar + window│
└──────┬───────┘   Bonjour       │  or Windows (Tauri)     │
       │            discovery    └───────────┬─────────────┘
       │ WatchConnectivity                   │ PTY / CLI
┌──────┴───────┐                  ┌──────────┴─────────────┐
│ Apple Watch  │                  │  opencode · claude     │
│  (watchOS)   │                  │  codex · aider         │
└──────────────┘                  └────────────────────────┘
```

## What you can do with BrewPing

### Send a command from anywhere in your home

Start the desktop service, pair once, and send instructions from your phone. BrewPing shows the agent's status while the command runs and returns the output when it finishes — you do not have to stay at the keyboard.

### Keep using the agents and models you already configured

BrewPing does not replace your agents or their logins. It discovers the CLI agents installed on your computer, reads the models each one is configured with, and lets you switch the active agent or model remotely. Your subscriptions, credentials, and permission settings stay exactly where they are.

### Approve risky commands before they run

Commands are checked before they reach the agent. BrewPing classifies dangerous operations (`rm -rf`, `git reset --hard`, `curl | sh`, and more) and holds them for your approval. Pick a mode: block only dangerous commands, confirm every command, or run without confirmations. Pending requests time out as denied — silence is never an approval.

## Connect a computer

Run the desktop service on the machine that should do the work:

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

Then pair your phone:

1. In BrewPing Desktop, open **Show Pairing Code** — a 6-digit code (and a QR code) appears.
2. On your phone, scan the QR code, or tap **Add Device** and enter the code.
3. Both devices must be on the **same local network**. BrewPing has no public relay and never connects to a machine you did not configure.

The pairing code is exchanged once for a long-lived token. On iOS the token is stored in the Keychain; on the desktop it is stored in `~/.brewping/pairing.json` with `0600` permissions. Every `/api/*` request carries `Authorization: Bearer <token>`; write requests also carry `X-BrewPing-Timestamp` and `X-BrewPing-Nonce` (120-second window, replay-protected).

## Use BrewPing from the CLI

The same CLI that ships with the desktop service can drive a session from a terminal or a script:

```bash
swift run BrewPing start                        # start an OpenCode session in a PTY
swift run BrewPing status                       # show the current session status
swift run BrewPing send "Fix the failing test"  # send a message to the session
swift run BrewPing attach                       # attach to the running session (Ctrl+D to detach)
swift run BrewPing stop                          # stop the session
```

## Control agents from iPhone, Apple Watch and Android

### iPhone and Android

Both apps share the same flow: discover computers on the current Wi-Fi, or add one by host and port; pair by scanning the QR code or typing the 6-digit code; then browse conversations, send instructions, switch agents and models, and approve commands.

### Apple Watch

The Watch app sends voice-dictated instructions, switches agents and models with swipes, and follows the live status of the running command.

### No computer at hand?

The iOS app can add a **Demo device** that simulates discovery, agents, sessions, and command results locally — the whole flow works with no hardware.

## Keep conversations and their folders together

### Conversations grouped by working folder

The phone shows conversations synced from the desktop, grouped by the folder each one is bound to. Pin, archive, and reopen conversations; the history stays with the conversation.

### Bind a working folder to a conversation

On desktop builds that support folder browsing, bind a working folder to a conversation so file operations happen where the conversation lives. Unbound conversations fall back to the agent's default folder.

### Per-conversation agent, model and approval

Agent, model, and approval level are conversation-level settings: switching the agent clears that conversation's model choice, and each conversation can use its own model without affecting the others.

## More built in

- **Multi-device** — keep several computers (macOS, Windows, Linux) and switch between them from the device bar.
- **Bonjour/mDNS discovery** — find computers on the current Wi-Fi without typing an IP address.
- **Model switching** — list the models each agent is configured with and switch remotely, immediately.
- **Approval modes** — safe (default), confirm-everything, or auto, at the global level or per conversation.
- **Markdown transcripts** — read agent output rendered as Markdown, including long responses.
- **Local network only** — no account, no analytics, no third-party SDKs; commands and output travel only between your phone and your own computer.
- **In-app language switch** — English and Simplified Chinese, switched inside the app without restarting it.

## Supported agents

BrewPing drives the CLI agents already installed on your computer. Product names and trademarks belong to their respective owners (see [Trademarks](#trademarks)).

| Agent | Mode | Command | Configuration read from |
|-------|------|---------|-------------------------|
| OpenCode | Session (interactive PTY) | `opencode` | `~/.config/opencode/opencode.json` |
| Claude Code | Headless (one-shot) | `claude` | `~/.claude/settings.json` |
| Codex CLI | Headless (one-shot) | `codex` | `~/.codex/config.toml` |
| Aider | Headless (one-shot) | `aider` | Aider configuration |

Install the ones you want to use:

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

Except for `POST /api/pair` and `GET /api/status`, every endpoint requires `Authorization: Bearer <token>`. Write endpoints additionally require `X-BrewPing-Timestamp` and `X-BrewPing-Nonce`.

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/pair` | Exchange a 6-digit pairing code for a long-lived token (public) |
| GET | `/api/status` | Device status, read-only health check (public) |
| GET | `/api/protocol/state` | Protocol state snapshot |
| GET | `/api/agents` | Installed agents |
| POST | `/api/agents/default` | Set the default agent |
| POST | `/api/agents/:id/switch` | Switch the active agent |
| GET | `/api/agents/:id/models` | Models configured for that agent (providers → models) |
| POST | `/api/agents/models/default` | Set the default model |
| POST | `/api/message` | Send a message |
| GET | `/api/message` | List messages |
| GET | `/api/message/:id` | Query the status of one command |
| POST | `/api/session/start` | Start a session |
| POST | `/api/session/stop` | Stop a session |
| GET / POST | `/api/approvals/mode` | Read or change the approval mode |
| GET | `/api/approvals` | Pending approval requests |
| POST | `/api/approvals/:id` | `approve`, `deny`, or `always_approve` |
| GET / POST | `/api/conversations` | List or create conversations |
| GET / PATCH / DELETE | `/api/conversations/:id` | Read, update, or delete one conversation |
| POST | `/api/conversations/:id/activate` | Activate a conversation |
| POST | `/api/discovery/refresh` | Refresh local network discovery |

## Configuration

BrewPing keeps its state in `~/.brewping/`:

- `device.json` — device identity (device ID, name)
- `pairing.json` — pairing token and temporary code (permissions `0600`)
- `approval.json` — global approval mode and always-allow rules (permissions `0600`)
- `config.json` — agent configuration (default agent, model preferences)
- `session.json` — current session state

## Requirements

- **macOS desktop**: macOS 13.0+
- **Windows desktop**: Windows with WebView2 (Tauri 2)
- **iPhone**: iOS 17.0+
- **Apple Watch**: watchOS 9.0+ (paired with the iPhone app)
- **Android**: Android 8.0+ (minSdk 26)
- Phone and computer must be on the **same local network**

## Beyond the local network

Local-network pairing is BrewPing's starting point, not its final shape.

`relay-server/` contains a TypeScript relay that is **not wired into the clients yet**. Until it is connected, BrewPing stays deliberately local: no accounts, no analytics, no third-party SDKs, and no traffic leaving the network you own. Commands, agent output, and voice audio stay on your phone and your own computer.

Approval gating is also scoped on purpose: it intercepts commands at the point where they enter the agent, so an agent that later pushes a shell command on its own is not covered by this release.

## Build from source

```bash
# macOS desktop (produces build/BrewPing Desktop.app)
./build-app.sh

# Windows desktop (Tauri 2 + axum)
cd Sources/BrewPingwinDesktop && npm install && npm run tauri dev

# Android
cd Android && ./gradlew assembleDebug        # Windows: gradlew.bat assembleDebug

# iOS / watchOS
open ios/BrewPing.xcodeproj
```

## Repository

- `Sources/App` — desktop core: HTTP API, routing, pairing store, approval gate
- `Sources/Agents` — agent discovery, manager, and CLI agent implementations
- `Sources/PTY` — pseudo-terminal handling for interactive agents
- `Sources/Session` — session lifecycle
- `Sources/Protocol` — wire protocol shared by every client
- `Sources/BrewPingDesktop` — macOS SwiftUI app (window + menu bar)
- `Sources/BrewPingwinDesktop` — Windows desktop app (Tauri 2 + axum + React)
- `Sources/BrewPing` — CLI entry point
- `ios/BrewPing` — iPhone app
- `ios/Watch` — Apple Watch app
- `Android` — Android app (Jetpack Compose)
- `relay-server` — TypeScript relay (not connected yet)
- `docs` — design and implementation notes
- `logo` — app icons and logo

## Trademarks

OpenCode, Claude, Claude Code, Codex, and Aider are trademarks of their respective owners. BrewPing is not affiliated with, endorsed by, or sponsored by them; these names appear only to describe compatibility.

BrewPing connects only to devices **you configured**, on your own local network. It does not connect to third-party devices and does not provide a public relay.

## License

MIT
