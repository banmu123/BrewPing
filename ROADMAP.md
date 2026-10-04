# BrewPing Roadmap

**BrewPing is a cross-device control layer for coding agents running on your own devices.**

Instead of replacing your coding agents or moving your code to the cloud, BrewPing gives you a
lightweight way to control the agents already running on your own machines — send instructions,
follow progress, and approve risky commands from your phone or watch, over your own network.

> **This is a product roadmap, not a task list.** It describes what BrewPing is becoming, at the
> level of product capabilities. Individual bugs, refactors, and file-level work belong in issues
> and pull requests.
>
> Objective, reproducible state lives in **[docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md)** — that
> document is the source of truth, and this roadmap follows it. Where the two could disagree, the
> status document wins.

**Legend** — ✅ shipped · 🟡 in progress · 🔲 planned · 💡 exploratory

---

## ✅ Foundation — Local-first control

The core product is built, and both desktop editions have published releases.

- **macOS desktop** — released in `v1.0.0`: a universal (Apple Silicon + Intel) DMG, Developer ID
  signed, notarized and stapled. A menu-bar service that drives CLI agents on that machine.
- **Windows desktop** — released in `v1.0.0`: Tauri 2 + axum, distributed as `setup.exe` / `.msi`.
- **Multi-agent** — drives the agent CLIs the user has already installed and configured:
  OpenCode (interactive session), Claude Code, Codex CLI, and pi (headless). BrewPing does not
  implement a coding agent of its own.
- **Phone and watch control** — send instructions, follow streaming output, and approve risky
  commands from iPhone, Apple Watch, or Android.
- **Agent and model selection** — choose the agent and the model a conversation runs on.
- **Approval gate** — commands can be intercepted before they reach the agent. It is a safety net
  for your own instructions, not a sandbox.
- **Conversations and working folders** — a conversation stays bound to the working directory it
  was created with.
- **Device discovery and pairing** — Bonjour / mDNS discovery on the local network, a 6-digit
  pairing code exchanged for a long-lived token. No account is involved.
- **Local-first by design** — no account system, no analytics, no telemetry, no third-party SDKs,
  and no server operated by this project in the request path.

## 🟡 Cross-platform and wearable experience — in progress

The mobile surfaces exist and are being finished, then aligned across platforms.

| Surface | Where it is today |
|---|---|
| iPhone / Apple Watch | In App Review — TestFlight only, no App Store listing yet |
| Android phone | Builds cleanly and targets API 36; not submitted to Google Play |
| Wear OS watch | Module lives in the repository and is covered by CI; not released, on no store |

Work in this phase:

- Carrying each mobile client through store submission and its first public release.
- Keeping feature parity across iPhone, Apple Watch, Android, and Wear OS — including a shared
  client core on Android so the phone and the watch behave the same way.
- Watch-first quick actions: voice dictation, reading replies, approving or rejecting.
- Notifications and approvals that remain usable when the phone is in a pocket.

## 🔲 Remote Access — planned

BrewPing is local-network first: pairing, discovery, and control assume the phone or watch and the
computer share a network. Reaching a machine from outside that network is, today, the user's own
network setup. This phase is about providing a supported path for exactly that need.

**Technical direction validated by a prototype.** `experimental/relay-server/` is a runnable
WebSocket relay prototype, and a client path now exists in the code on macOS and iPhone — off by
default on both ends, and with the iPhone entry point **not exposed in the current build** (see
`docs/PROJECT_STATUS.md`). What it demonstrates today:

- A WebSocket server with two roles — desktop and agent.
- Device identity through `deviceId`, connection management, and routing to a specific device.
- Heartbeat, plus online / offline events.
- A small REST surface (health check, device list, send) and containerized deployment.
- Basic relay tests, plus a shared-token mode and metadata-only logging (relayed message
  contents are not written to the relay's logs).

It is an **early prototype**: not part of any build or release, unencrypted on the wire, with no
rate limiting or production observability, and it must not be deployed to a public or untrusted
network as-is.

**Still required before this can become a product capability:**

- Secure pairing and device-level authorization on the relay itself (today the relay checks only
  its own shared token; device identity is verified by the desktop endpoint behind it).
- Transport security (WSS / TLS) terminated in front of the relay.
- Reconnection and recovery semantics validated across real networks, not just localhost.
- Device management: seeing and revoking which devices may reach a machine remotely.
- Abuse protection and rate limiting, production deployment, and observability.
- Real cross-network testing, not just localhost.

Peer-to-peer approaches such as NAT traversal or WebRTC are **not** committed here and are not
implemented today; they are possible future options, to be explored only if they prove necessary.

> Local-first stays the default. Remote Access is an optional extension for people who need to
> reach their machine from another network — not a replacement for local mode.

## 🔲 AI Agent Control Layer — planned

BrewPing remains a control layer over agents that already run on the user's machines.

- A unified view of what the agents on your machines are doing.
- Managing several agents — and several computers — from one place.
- Finer-grained approval: per command, per category, with remembered decisions.
- Background and long-running work with notifications when it needs attention.
- Voice control beyond the watch, for hands-free operation.

Explicitly **not** in this phase: writing our own coding agent, hosting the user's code, or
replacing the agent CLIs the user has installed.

## 🔲 Developer Ecosystem — planned

Integrations that keep BrewPing in the loop with the tools a developer already works in.

- GitHub / GitLab connectivity and webhooks.
- Linking a conversation to the pull request or issue it produced.
- Notification integrations and triggers for external automation.

The boundary stays the same: BrewPing is the control and collaboration layer, not a new IDE.

## 💡 Long-term explorations

Exploratory directions, not commitments:

- Multi-machine setups that behave as one surface.
- Richer state synchronization across devices.
- More natural voice and assistant-style interaction.
- A personal command center for agent work.
- Coordination between multiple agents.

## Purchase model

BrewPing is built around a **one-time purchase** rather than a subscription. Core capabilities keep
evolving under that model, and advanced capabilities such as Remote Access are planned to arrive as
part of the product over time.

Pricing, commercial terms, and any infrastructure limits are deliberately **not** defined here.
They belong in the project's pricing and terms documents if and when those exist.

## What this roadmap does not promise

- **No dates.** Phases move as the work moves; nothing here is a schedule commitment.
- **No adoption figures.** This repository does not publish user counts, download numbers, or
  usage metrics.
- **No claim that prototype code is shipped.** Everything under `experimental/` is prototype work
  and is described as such.

## Maintaining this document

- Describe **capabilities**, not implementation details — no function names, file paths, or issue
  numbers, so the roadmap stays readable as the code changes.
- Keep the four state markers honest. A capability moves to ✅ only when it is actually released
  (or plainly verifiable in the repository), and never before.
- When this file and [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) disagree about what exists
  today, fix this file: the status document is the source of truth.
