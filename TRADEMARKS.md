# Trademarks

BrewPing **drives** command-line coding agents that you installed yourself. It does not bundle,
redistribute, or relicense any of them, and it is **not affiliated with, endorsed by, or sponsored
by** the companies behind them.

The names below appear in this repository, in the app UI, and in the documentation **only to
describe compatibility** — which agent BrewPing can detect and run. All rights belong to their
respective owners.

| Name | Owner (as commonly attributed) | How BrewPing refers to it |
|---|---|---|
| OpenCode | The OpenCode project | Detects the `opencode` CLI and reads `~/.config/opencode/opencode.json` |
| Claude, Claude Code | Anthropic PBC | Detects the `claude` CLI and reads `~/.claude/settings.json` |
| Codex, Codex CLI | OpenAI | Detects the `codex` CLI and reads `~/.codex/config.toml` |
| pi | The pi project (`@earendil-works/pi-coding-agent`) | Detects the `pi` CLI and reads `~/.pi/agent/*.json` |

Notes:

- Installer commands in the READMEs point at **each vendor's own distribution channel**. BrewPing
  does not host or mirror any of them.
- The ownership column records the owner commonly attributed to each name at the time of writing.
  It is **not** a statement about trademark registration status; if a name is used incorrectly here,
  a correction is welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
- BrewPing's own name, logo, and code are covered by [LICENSE](LICENSE) (MIT). MIT covers the
  **code**; it does not grant rights to any third-party trademark listed above.
