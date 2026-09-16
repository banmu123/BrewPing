# Contributing to BrewPing

Thanks for taking the time to look at BrewPing. Issues and pull requests are welcome.

## Before you start

BrewPing is a **local-network remote control** for coding agents that are already installed on your
machine. Two consequences worth knowing before you open a PR:

- It never bundles, replaces, or reconfigures an agent. Config discovery is **read-only** in the
  normal path; writes happen only through the explicit provider-management features.
- Privacy is a feature, not a nice-to-have: no analytics, no telemetry, no third-party SDKs, and no
  server of ours in the request path. PRs that add any of those will be declined.

## Repository layout

| Path | What lives there |
|---|---|
| `Sources/App` | Desktop core: HTTP API, routing, pairing store, approval gate, conversations |
| `Sources/Agents` | Agent discovery + the OpenCode / Claude Code / Codex / pi drivers |
| `Sources/PTY`, `Sources/Session`, `Sources/Protocol` | Sessions, pseudo-terminals, shared wire protocol |
| `Sources/BrewPingDesktop` | macOS app (SwiftUI, window + menu bar) |
| `Sources/BrewPingwinDesktop` | Windows desktop (Tauri 2 + axum + React) |
| `Sources/BrewPing` | CLI entry point |
| `ios/BrewPing`, `ios/Watch` | iPhone and Apple Watch apps |
| `Android` | Android app (Jetpack Compose) |
| `relay-server` | Experimental TypeScript relay — **not wired into any client** |

## Build and test

```bash
# Swift core + macOS app
swift build                    # all targets
swift test                     # 41 unit tests (vendor-native config invariants)
./build-app.sh                 # produces build/BrewPing Desktop.app

# iOS / watchOS
open ios/BrewPing.xcodeproj    # pick your team, then Run

# Localization check (must pass before touching any user-facing string)
python3 ios/Scripts/check_localization.py

# Windows desktop
cd Sources/BrewPingwinDesktop && npm install && npm run tauri dev
cargo test                     # in Sources/BrewPingwinDesktop/src-tauri

# Android
cd Android && ./gradlew assembleDebug
```

## What CI runs

`.github/workflows/ci.yml` runs on every push and pull request:

1. **Swift** — `swift build` + `swift test` on macOS.
2. **Apple targets** — compiles the iOS and watchOS schemes with signing disabled, so a broken
   project file or a missing resource fails the PR instead of the release.
3. **Hygiene** — LICENSE present, no compiled artifacts (`build*/`, `dist/`, `*.app`, `node_modules`)
   committed, both READMEs present.

`release-mac.yml` (tag-triggered) is the release pipeline: universal build → Developer ID signing →
notarization → staple → DMG attached to the GitHub release.

## Conventions this repo follows

- **Commit messages**: `type(scope): summary` — `feat`, `fix`, `docs`, `chore`, `refactor`, `test`;
  scope is the area (`mac`, `ios`, `watch`, `win`, `android`, `memory`, …).
- **No third-party Swift dependencies.** The core is SwiftPM with internal targets only; keep it
  that way unless there is a strong reason.
- **User-facing strings ship in both languages.** macOS strings live in
  `Sources/BrewPingDesktop/DesktopStrings.swift`, Windows in `src/i18n/locales.ts`, iOS in
  `*.lproj/Localizable.strings`. Change both ends in the same PR — and run the localization check.
- **New Swift files must be registered in the Xcode project** when they belong to the iOS/watchOS
  targets (a file that is not in the project simply will not compile into the app).
- **Configuration writes are dangerous by nature.** Any change to how an agent's config is merged or
  written must come with a test: silently corrupting someone's `~/.claude/settings.json` is the worst
  failure mode this project has.

## Pull request checklist

- [ ] `swift build` and `swift test` pass locally
- [ ] iOS / watchOS still compile if you touched the project file or shared code
- [ ] User-facing text added or changed on **both** platforms (and localization check passes)
- [ ] No secrets, tokens, personal paths, or machine-specific hostnames in the diff
- [ ] Documentation updated when behaviour changes (`README.md` + `README.zh-CN.md`)

## Reporting bugs

Please include: platform and version (macOS / iOS / watchOS / Windows / Android), how the phone and
computer are connected (same Wi-Fi? manual IP?), the agent involved, and what you expected to happen.
Logs from `Console.app` filtered by `BrewPing` help a lot for the mobile apps.
