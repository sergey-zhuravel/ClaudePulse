# Security Policy

## How Claude Pulse Works

Claude Pulse supports two authentication modes to fetch usage data. It does **not** store, transmit, or share any of your data with third parties.

### Authentication modes

**CLI API mode** — If you use Claude Code CLI (`claude login`), the app reads your existing OAuth token from `~/.claude/.credentials.json` or macOS Keychain. The token is validated against the Anthropic API before use. Usage data is fetched via `GET /api/oauth/usage`; only while that endpoint is rate-limited does the app fall back to a minimal `POST /v1/messages` request and read the rate-limit response headers. If the token expires, the app refreshes it itself using the stored OAuth refresh token (the same `platform.claude.com/v1/oauth/token` flow Claude Code uses) and writes the updated credentials back to the original store (credentials file or Keychain) so Claude Code stays logged in. If the refresh fails, the app falls back to waiting for Claude Code to refresh the token (checking the credentials file/Keychain periodically).

**WebView mode** — A hidden `WKWebView` loads `claude.ai/settings/usage` using your stored browser session. A JavaScript interceptor captures API responses containing usage data.

### What the app accesses

- **Claude Code CLI credentials** (CLI mode) — OAuth token read; the access token is kept in memory for API calls. When the token expires, the app performs an OAuth refresh and writes the updated credentials back to their original location (credentials file or Keychain item) — only the token fields are replaced, everything else is preserved. The write uses the Security framework directly, so credentials never pass through subprocess arguments.
- **`~/.claude.json`** (CLI mode) — Read-only access to extract the account email address for display. No data is modified.
- **claude.ai cookies** (WebView mode) — stored in the system's default `WKWebsiteDataStore`, used to authenticate with Claude. Never read or exported by the app.
- **Usage data** — utilization percentages, limits, and reset times for session (5h), weekly, Sonnet-only, and Claude Design quotas, plus plan type. Kept in memory only.
- **Email address** — extracted from `~/.claude.json` (CLI mode) or the Claude UI (WebView mode). Stored in memory only, never persisted to disk.

### What the app does NOT do

- Does not store or persist credentials or tokens to disk (the only write is the refreshed OAuth credentials going back into Claude Code's own store)
- Does not modify any Claude Code configuration other than the OAuth token fields during a refresh
- Does not send data to any server other than `api.anthropic.com`, `platform.claude.com` (OAuth token refresh), `claude.ai`, and GitHub (for update checks)
- Does not log or persist usage data to disk
- Does not access any Claude conversations or message content
- Does not modify any data on claude.ai

### Network connections

| Destination | Purpose |
|-------------|---------|
| `api.anthropic.com` | Fetch usage data via OAuth API (CLI mode) |
| `platform.claude.com` | OAuth token refresh when the access token expires (CLI mode) |
| `claude.ai` | Load usage settings page, authenticate (WebView mode) |
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
