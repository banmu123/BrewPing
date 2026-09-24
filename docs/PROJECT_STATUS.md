# Project Status

Objective status of the BrewPing repository. Every statement here is one of three kinds, and the
kind matters:

1. **Repository state** — visible in the files, code, and git history of this repository.
2. **Reproducible results** — the build and test commands listed below produce them on your machine.
3. **Distribution status maintained by the project owner** — store listings, review, and beta
   distribution happen in App Store Connect, Google Play Console, and TestFlight. Those live
   **outside** this repository and cannot be re-derived from it; the entries below are the maintainer's
   own record, and the linked stores/releases can be checked independently.

**No adoption metrics are claimed.** The project does not publish user counts, download numbers, or
third-party usage data, because none of that is verifiable from inside the repository.

Last reviewed: 2026-09-24.

---

## 1. Development status

| | |
|---|---|
| Status | **Actively developed.** Both desktop builds and the iPhone / Apple Watch apps have published releases; Android is built but not published — see [Distribution status](#11-distribution-status) |
| Main branch | `main` — all work lands here; there are no maintenance branches |
| Latest release | `v1.0.0` (git tag), published as a GitHub Release |
| Release assets | macOS: three signed + notarized DMG variants (universal / Apple Silicon / Intel) · Windows: `setup.exe` and `.msi` |
| Maintainers | 1 (a single active maintainer — see [Maintenance](#4-maintenance)) |
| Language | English + Simplified Chinese across all user-facing surfaces |

### 1.1 Distribution status

Where each surface actually is today. *Built* means the artifact can be produced from this
repository; it does **not** mean the surface is publicly available.

| Surface | Stage | What exists today | How to get it |
|---|---|---|---|
| macOS desktop | **Released** | `v1.0.0` GitHub Release — Universal / Apple Silicon / Intel DMG, Developer ID signed, notarized, stapled | GitHub Release, or build from source |
| Windows desktop | **Released** | `v1.0.0` GitHub Release — `setup.exe` + `.msi` | GitHub Release, or `npm run tauri dev` |
| iPhone / Apple Watch | **Available** — App Store | The iPhone app, with its Apple Watch app, distributed through the App Store | App Store (search for **BrewPing**) |
| Android phone | **Built and ready — not submitted** to Google Play | `./gradlew assembleDebug` and the release bundle build cleanly; already targets API 36 as Google Play requires | Build from source |
| Wear OS watch | **Not released** | `Android/wear` module builds and is covered by CI | Build from source; on no store |

The macOS, Windows, and iPhone / Apple Watch rows are checkable against the GitHub Release and the
App Store listing. The Android and Wear OS rows come from the maintainer's own record (kind 3 above):
there is **no Google Play listing** at the time of writing. No store install numbers, download counts,
or tester counts are claimed anywhere in this repository.

## 2. Supported platforms

| Platform | Requirement | Notes |
|---|---|---|
| macOS desktop | macOS 13.0+ | Universal binary (Apple Silicon + Intel); signed, notarized, stapled |
| Windows desktop | Windows 10/11 + WebView2 | Tauri 2 + axum; ships as `setup.exe` / `.msi` |
| iPhone | iOS 17.0+ | `com.brewping.ios` · **available on the App Store** |
| Apple Watch | watchOS 11.6+ | Paired with the iPhone app; voice dictation + reply reading · **available on the App Store** |
| Android phone | Android 8.0+ (minSdk 26) | Jetpack Compose; `targetSdk`/`compileSdk` 36 · **built, not submitted to Google Play** |
| Wear OS watch | Wear OS 3.0+ (minSdk 30) | **In repository, not released yet** — see limitations |
| Network | Phone/watch and computer on the same local network | No public relay is shipped |

## 3. Test & CI status

Unit tests live next to the code they cover and run **without a device or emulator**.

| Suite | Where | Count (methods) | How to run |
|---|---|---|---|
| Swift core | `Tests/BrewPingCoreTests/` | **66** | `swift test` (macOS) |
| Windows desktop (Rust) | `Sources/BrewPingwinDesktop/src-tauri` | **318** | `cargo test --locked` |
| Android (`:core` + `:app`) | `Android/core/src/test`, `Android/app/src/test` | **109** | `cd Android && ./gradlew test` |

CI — [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) — runs on every push and PR, plus a
**nightly** schedule:

1. `swift build` + `swift test` (macOS runner)
2. iOS + watchOS schemes compiled with signing disabled
3. Windows: `npm ci`, `npx tsc`, `vite build`, `cargo test --locked`
4. Android: JDK 17, SDK platform 36, `./gradlew test`, `assembleDebug`, `:wear:assembleDebug`
5. Repository hygiene: LICENSE present and recognizable, no compiled artifacts tracked, both
   READMEs present

The nightly run exists to catch **runner toolchain drift** (Xcode / Swift / JDK / Node upgrades)
before it breaks someone's pull request.

**CI status:** the badge at the top of `README.md` reflects the latest run on `main`, and
`ci.yml` is the authoritative record — the jobs listed above are exactly what it executes.

> Honesty note: the Swift and Android counts above are method counts of the committed test files.
> The Swift suite was last executed by the maintainer on macOS; the Android suite and the Rust suite
> were executed on Windows. CI re-runs all three on public runners — check the badge on the README
> for the authoritative result.

## 4. Maintenance

| Process | How it works |
|---|---|
| Maintainer | One active maintainer (`banmu123`) — creator of the project, reviews all pull requests, cuts releases, and handles security reports |
| Release process (macOS) | `v*` tag → [`.github/workflows/release-mac.yml`](../.github/workflows/release-mac.yml): universal build → Developer ID sign → notarize → staple → DMG attached to the release |
| Release process (macOS, practical note) | The workflow needs Apple signing secrets that are **not** configured in this repository, so macOS packages are currently built locally by the maintainer and attached to the release by hand |
| Release process (Windows) | Built and attached to the GitHub Release |
| Issue process | Issues are triaged on the repository; bug reports should include platform, version, connection mode, and the agent involved (see [CONTRIBUTING.md](../CONTRIBUTING.md)) |
| PR process | CI must pass; the pull-request template asks about tests, iOS/watchOS compilation, localization, and secrets hygiene |
| Security reporting | Private GitHub Security Advisories, or email — see [SECURITY.md](../SECURITY.md) |
| Contribution conventions | Commit style, localization requirements, config-write test requirements: [CONTRIBUTING.md](../CONTRIBUTING.md) |

## 5. Security status

- The security model, token handling, and the **explicitly out-of-scope** list are documented in
  [SECURITY.md](../SECURITY.md).
- The approval gate intercepts commands **as they enter the agent**. It is a safety net for the
  user's own instructions, **not a sandbox**.
- No account system, no analytics, no telemetry, no third-party SDKs, and no server operated by the
  maintainer is in the request path.
- `experimental/relay-server/` is an unauthenticated, payload-logging prototype that **no client
  connects to**. It is deliberately outside the product's security boundary and must not be exposed
  to a public network.

## 6. Known limitations

These are real, currently true, and worth knowing before judging the project:

1. **Local network oriented.** Pairing and control assume the phone/watch and the computer are on
   the same LAN. There is **no official public relay** and no hosted service.
2. **Cross-network use is the user's own responsibility.** Tools like Tailscale or WireGuard can
   bridge networks, but that is a user-side network setup; BrewPing does not provide or operate it.
3. **Third-party agents are external dependencies.** OpenCode / Claude Code / Codex CLI / pi are
   installed and configured by the user. Their own behaviour, versions, and configuration formats
   are out of this project's control.
4. **The approval gate is not a sandbox** (repeated on purpose).
5. **Android and Wear OS are not published.** The Android app builds cleanly but has **not been
   submitted to Google Play**, and the `Android/wear` module has had no device testing and no store
   submission. iOS, watchOS, macOS, and Windows are released. See
   [Distribution status](#11-distribution-status).
6. **The relay prototype is not on the product path.** It is parked under `experimental/` with no
   client wired to it.
7. **Windows packaging version metadata is not aligned with the release version** (internal
   `0.1.0` vs release asset `1.0.0`). Tracked; not yet corrected.
8. **No automated UI tests.** Desktop, iOS/watchOS, Android, and Wear UI behaviour is verified
   manually.
9. **Single maintainer.** Bus factor is 1; response times depend on one person.
10. **App Store metrics are not in the repository.** Install counts, ratings, and tester numbers live
    in App Store Connect and cannot be verified from this repo — they are intentionally not claimed
    anywhere in the documentation.

## 7. Reproducing this status

```bash
# Swift core (macOS)
swift build && swift test

# Windows desktop
cd Sources/BrewPingwinDesktop/src-tauri && cargo test --locked

# Android (JDK 17 + SDK platform 36)
cd Android && ./gradlew test && ./gradlew assembleDebug

# Repository hygiene, same checks CI runs
git ls-files | grep -E '(^|/)(build[^/]*|dist|node_modules|DerivedData|target)/|\.app/|\.xcarchive' || echo "clean"
test -f LICENSE && test -f README.md && test -f README.zh-CN.md && echo "docs present"
```
