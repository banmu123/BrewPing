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

## Request handling and pairing limits — what is actually enforced

These are **hardening measures, not a sandbox**. They are documented here so reports can be
judged against real behaviour rather than assumptions.

### HTTP request framing (`Sources/App/HTTPServer.swift`)

The desktop listener speaks a deliberately small subset of HTTP/1.1 and **rejects** anything it
cannot frame unambiguously, instead of guessing:

| Condition | Response |
|---|---|
| `Content-Length` negative, non-numeric (`+5`, `1.5`, `0x10`), or empty | `400` |
| `Content-Length` appears more than once — **even with identical values** | `400` |
| `Content-Length` larger than 8 MiB (also covers integer overflow) | `413` |
| Any `Transfer-Encoding` (chunked is **not** supported) | `400` |
| Request line malformed, header without `:`, obsolete line folding, control characters | `400` |
| Request head larger than 1 MiB (terminator seen or not) | `431` |

The same checks run whether the head and body arrive in one TCP segment or across many, because
they are applied while parsing the head — before any body is read or allocated. "Invalid length
means zero" is never used as a fallback: that silently turns a request with a body into an empty
one. A malformed request closes only that connection; it cannot take the desktop process down.

### Pairing code attempts (`Sources/App/PairingStore.swift`)

The code stays **6 digits, valid for 10 minutes, single-use**. On top of that:

- **Per source**: 5 failed attempts within 5 minutes → that source is refused for 60 seconds.
- **Global**: 30 failed attempts within 5 minutes across all sources → everybody is refused for
  60 seconds. This is the backstop against simply rotating source addresses.
- "Source" is the peer address reported by Network.framework for that TCP connection. Values from
  `X-Forwarded-For` and friends are **never** consulted. Relayed (tunnelled) requests have no peer
  address and share one bucket.
- A rate-limited request is rejected **before** the code is compared, so a correct guess during a
  cooldown does not succeed. A successful pairing clears that source's failure history.
- State is in memory, bounded to 256 sources (least-recently-seen evicted first), and pruned by
  the failure window.
- Guesses made while **no code is being displayed** are not counted — they cannot succeed, and
  counting them would let anyone pre-fill the global limit before the user opens the pairing sheet.

**Not covered by the above:** the counters are per-process and reset on restart; there is one
long-lived token per desktop with no per-device revocation; per-source limits are per IP address,
so an attacker with many addresses only meets the global cap; and the global cap means a
determined attacker can make the legitimate user wait out a 60-second cooldown. The traffic itself
is still plain HTTP on the LAN.

## Explicitly out of scope

- Anyone who already has the pairing token or physical/administrative access to the paired computer.
- The **experimental `experimental/relay-server/`** prototype and the opt-in Remote Access path
  that uses it. The prototype sits outside the product's security boundary: its only gate is a
  shared token, it does not authenticate devices itself (the desktop endpoint behind it still
  verifies the pairing token), the wire is unencrypted, and there is no rate limiting. Running it
  on a public network is unsupported and your own responsibility (see
  `experimental/relay-server/README.md`). Both ends are **off by default**.
- Third-party agents themselves (OpenCode, Claude Code, Codex CLI, pi) and their own configuration
  schemas — report those upstream.
- Social engineering, phishing, or attacks requiring the user to disable security features.

## Supported versions

The project ships from `main`; fixes land there and in the next release. There are no maintained
release branches — please test against the latest `main` (or the newest TestFlight build) before
reporting.
