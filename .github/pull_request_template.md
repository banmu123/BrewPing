<!--
Thanks for contributing to BrewPing.
Keep this short — a reviewer should understand the change without opening the diff.
-->

## What this changes

<!-- One or two sentences. If it fixes a bug, say what the bug was. -->

## Platform(s) touched

- [ ] Swift core (`Sources/App`, `Agents`, `PTY`, `Session`, `Protocol`)
- [ ] macOS desktop (`Sources/BrewPingDesktop`)
- [ ] Windows desktop (`Sources/BrewPingwinDesktop`)
- [ ] iOS / watchOS (`ios/`)
- [ ] Android (`Android/`)
- [ ] Docs / CI only

## Checklist

- [ ] `swift build` and `swift test` pass locally (if the Swift core was touched)
- [ ] iOS / watchOS still compile (if the project file or shared code was touched)
- [ ] User-facing text added or changed on **both** platforms, and
      `python3 ios/Scripts/check_localization.py` passes
- [ ] No secrets, tokens, personal paths, or machine-specific hostnames in the diff
- [ ] README (both languages) updated if behaviour or requirements changed
- [ ] If agent config merging / writing changed: a test was added — silently
      corrupting someone's `~/.claude/settings.json` is this project's worst failure mode

## How it was verified

<!-- Commands you ran, screenshots, or the manual steps you followed. -->
