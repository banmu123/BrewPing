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
| `experimental/relay-server` | Parked TypeScript prototype — **not part of the shipped product, no client connects to it** |

## Build and test

```bash
# Swift core + macOS app
swift build                    # all targets
swift test                     # 66 unit tests (config invariants + execution state machine)
./build-app.sh                 # produces build/BrewPing Desktop.app

# iOS / watchOS
open ios/BrewPing.xcodeproj    # pick your team, then Run

# Localization check (must pass before touching any user-facing string)
python3 ios/Scripts/check_localization.py

# Windows desktop
cd Sources/BrewPingwinDesktop && npm install && npm run tauri dev
cargo test                     # in Sources/BrewPingwinDesktop/src-tauri

# Android (phone app + Wear OS module)
cd Android && ./gradlew test             # 83 JVM unit tests (:core + :app)
cd Android && ./gradlew assembleDebug    # phone APK
cd Android && ./gradlew :wear:assembleDebug   # Wear OS APK (module in repo, not released yet)
```

## What CI runs

`.github/workflows/ci.yml` runs on every push and pull request:

1. **Swift** — `swift build` + `swift test` on macOS.
2. **Apple targets** — compiles the iOS and watchOS schemes with signing disabled, so a broken
   project file or a missing resource fails the PR instead of the release.
3. **Windows desktop** — `npm ci` + `npx tsc` on the frontend, `cargo test --locked` on the Rust side.
4. **Android** — `./gradlew test assembleDebug :wear:assembleDebug` with JDK 17 — the 83 JVM unit
   tests plus both app modules (no APK is published from CI).
5. **Hygiene** — LICENSE present **and still a plain MIT text** (extra sections appended to it
   break GitHub's license detection), no compiled artifacts (`build*/`, `dist/`, `target/`, `*.app`,
   `node_modules`, `DerivedData`) committed, both READMEs present.

The same suite also runs **nightly** (`schedule`) on the default branch: that is how toolchain drift
gets caught — a runner image upgrading Xcode / Swift / JDK and breaking the build shows up in the
nightly run instead of on your next push.

`release-mac.yml` (tag-triggered) is the release pipeline: universal build → Developer ID signing →
notarization → staple → DMG attached to the GitHub release.

## Conventions this repo follows

- **Commit messages**: `type(scope): summary` — `feat`, `fix`, `docs`, `chore`, `refactor`, `test`;
  scope is the area (`mac`, `ios`, `watch`, `win`, `android`, `memory`, …).
- **No third-party Swift dependencies.** The core is SwiftPM with internal targets only; keep it
  that way unless there is a strong reason.
- **User-facing strings ship in both languages.** macOS strings live in
  `Sources/BrewPingDesktop/DesktopStrings.swift`, Windows in `src/i18n/locales.ts`, iOS in
  `*.lproj/Localizable.strings`, and Android / Wear OS in `res/values/strings.xml` +
  `res/values-zh/strings.xml` (identical key sets on both sides). Change both ends in the same PR —
  and run the localization check.
- **New Swift files must be registered in the Xcode project** when they belong to the iOS/watchOS
  targets (a file that is not in the project simply will not compile into the app).
- **Facts live in one place.** Test counts, platform requirements, and the relay's status are
  stated in `README.md` / `README.zh-CN.md` and `docs/PROJECT_STATUS.md`. When a suite grows or a
  platform requirement changes, update them in the same PR instead of letting the numbers drift.
- **Configuration writes are dangerous by nature.** Any change to how an agent's config is merged or
  written must come with a test: silently corrupting someone's `~/.claude/settings.json` is the worst
  failure mode this project has.

## Workflow & CI security conventions

These rules apply to every file under `.github/workflows/`:

- **Least privilege, escalated per job.** Workflows start from `permissions: contents: read`; only
  the job that actually needs to write (the release job) gets `contents: write` — declared on that
  job, not at the workflow level.
- **Third-party actions are pinned to a full commit SHA** with the human-readable version in a
  trailing comment (`uses: owner/action@<40-hex> # v1`). GitHub-official actions (`actions/*`) may
  keep floating major tags. [Dependabot](.github/dependabot.yml) opens a grouped PR weekly to keep
  the pinned SHAs current — pinned does not mean stale.
- **No credentials leak into later steps.** Every `actions/checkout` uses
  `persist-credentials: false`, so the token is not left in `.git/config` for subsequent steps.
- **Secrets are scoped to the step that consumes them** (`env:` on that single step), never at
  workflow or job level, and never echoed.
- **Every job has a `timeout-minutes`** so a hung step cannot burn the runner indefinitely.
- **Concurrency is explicit**: pull-request runs cancel their own predecessors, while `main`,
  manual and scheduled runs are never cancelled — and the release workflow is never cancelled
  at all (interrupting it can leave a half-uploaded release or an unstapled artifact).
- **CI must never need signing material.** Apple targets are built with
  `CODE_SIGNING_ALLOWED=NO`; the Developer ID certificate and notarization credentials exist only
  in the release workflow, only in the steps that use them.

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
