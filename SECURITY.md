# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for anything exploitable.

- Preferred: GitHub **Security Advisories** → *Report a vulnerability* on this repository
- Or email: `czkbanmu@163.com` (PGP not required)

Expect an initial reply within a few days. Please include the version, platform, and a minimal
reproduction; if the issue involves the pairing or approval flow, describe the network setup
(same LAN? manual IP? relay involved?).

## What this project is, security-wise

BrewPing is a **local-network remote control**: the desktop service listens on your LAN and the
paired phone can send instructions that an agent will execute **on your computer**. That is the
product, so the security boundary is:

1. **The pairing token is equivalent to command execution on that machine.** Treat it like a
   password: it is stored with `0600` permissions on the desktop (`~/.brewping/pairing.json`) and in
   the iOS Keychain. Token leakage, missing authentication on a new endpoint, or a way to bypass the
   timestamp/nonce replay window are all in scope.
2. **The pairing code is single-use and expires after 10 minutes.** Ways to reuse it, brute-force it,
   or read it from a log are in scope.
3. **The approval gate is a safety net, not a sandbox.** It intercepts commands at the point where
   they enter the agent; a shell command that an agent spawns on its own is **not** covered. Reports
   are still welcome for bypasses that defeat the gate for *user-submitted* commands.
4. **The agent's own configuration files are read, and in provider-management flows written.** Path
   traversal, unintended overwrites, or writing outside the intended file are in scope — a silently
   corrupted agent config is a security-relevant bug in this project.

## Explicitly out of scope

- Anyone who already has the pairing token or physical/administrative access to the paired computer.
- The **experimental `relay-server/`**, which is deliberately unauthenticated, logs relayed payloads,
  and is **not wired into any client**. It is published as an early prototype; running it on a public
  network is unsupported (see `relay-server/README.md`).
- Third-party agents themselves (OpenCode, Claude Code, Codex CLI, pi) and their own configuration
  schemas — report those upstream.
- Social engineering, phishing, or attacks requiring the user to disable security features.

## Supported versions

The project ships from `main`; fixes land there and in the next release. There are no maintained
release branches — please test against the latest `main` (or the newest TestFlight build) before
reporting.
