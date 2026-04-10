# Security Policy

## How Claude Pulse Works

Claude Pulse uses a hidden WKWebView to load `claude.ai/settings/usage` and extract usage data. It does **not** store, transmit, or share any of your data with third parties.

### What the app accesses

- **claude.ai cookies** — stored in the system's default `WKWebsiteDataStore`, used to authenticate with Claude. Never read or exported by the app.
- **Usage data** — message counts, limits, reset times, and plan type are extracted from the Claude settings page and kept in memory only.
- **Email address** — extracted from the Claude UI for display in the popover. Stored in memory only, never persisted to disk.

### What the app does NOT do

- Does not store credentials or tokens
- Does not send data to any server other than `claude.ai` and GitHub (for update checks)
- Does not log or persist usage data to disk
- Does not access any Claude conversations or message content
- Does not modify any data on claude.ai

### Network connections

| Destination | Purpose |
|-------------|---------|
| `claude.ai` | Load usage settings page, authenticate |
| `raw.githubusercontent.com` | Check for app updates (Sparkle appcast) |
| `github.com` | Download app updates (DMG from releases) |

### Code signing & updates

- The app is signed with an Apple Developer certificate and notarized by Apple
- Updates are distributed via [Sparkle 2](https://sparkle-project.org/) with EdDSA (Ed25519) signature verification
- Update integrity is verified cryptographically before installation

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.1.x   | Yes       |
| 1.0.x   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. Open an issue at **https://github.com/sergey-zhuravel/ClaudePulse/issues**
2. Include a description of the vulnerability and steps to reproduce

Critical issues will be patched and released as soon as possible.

## Third-Party Dependencies

| Dependency | Purpose | License |
|------------|---------|---------|
| [Sparkle 2](https://github.com/sparkle-project/Sparkle) | App auto-updates | MIT |

No other third-party code or services are used.
