# Claude Pulse
<p align="center">
<img width="300" height="300" alt="App Icon" src="https://github.com/user-attachments/assets/e11e9496-8caa-45e9-a3e0-9a4c85eca7e2" />
</p>

## Overview
A native macOS menu-bar app that displays Claude Code usage in real time
<p align="center">
<img width="400" alt="Demo Gif" src="https://github.com/user-attachments/assets/258c0956-baee-489e-af9d-9d63f7acb01a" />
</p>

## Features
  - **Real-time usage tracking** — See your current session, weekly (all models), and Sonnet-only limits at a glance                                                                                            
  - **Menu bar percentage** — Always-visible usage percentage right in your menu bar                                                                                                                          
  - **Session reset countdown** — Know exactly when your limits reset                                                                                                                                           
  - **Smart usage hints** — Context-aware tips that appear as you approach your limits                                                                                                                        
  - **Auto-refresh** — Configurable polling interval (30s to 10m) keeps data fresh                                                                                                                              
  - **One-click sign in** — Authenticate with your Claude account via built-in web view                                                                                                                         
  - **Auto-updates** — Sparkle-powered updates with EdDSA signature verification                                                                                                                                
  - **Right-click menu** — Quick access to usage info, refresh interval, update check, and log out                                                                                                              
  - **Stale data warnings** — Visual indicator when data hasn't been refreshed recently                                                                                                                         
  - **Lightweight** — Runs as a menu bar accessory with no Dock icon 
## Installation

> **Requires macOS 13 Ventura or later.**

### Step 1 — Download

Download the latest **ClaudePulse.dmg** from the [Releases page](https://github.com/sergey-zhuravel/ClaudePulse/releases/latest).

### Step 2 — Install

1. Double-click `ClaudePulse.dmg` to mount it
2. Drag **ClaudePulse** into the **Applications** folder shortcut

### Step 3 — Log in to Claude

A browser window opens automatically on first run. Log in to your Claude Code account normally. The window closes by itself when login succeeds and the app icon appears in your menu bar.

## How it works

### Data source

The app embeds a hidden `WKWebView` that loads `claude.ai/settings/usage` using your stored browser session (via `WKWebsiteDataStore.default()` — the same cookie store Safari uses for WebKit-based apps).

A JavaScript **fetch/XHR interceptor** is injected at document start, before any page script runs. It captures every API response that mentions usage, limits, or quotas and forwards the raw JSON to Swift. This gives session-window data (e.g. the 5-hour rate-limit window) not visible in the page's DOM text. A DOM-text extraction pass runs 5 s after page load as a fallback.

### Cookie persistence

`WKWebsiteDataStore.default()` persists cookies to disk between app launches automatically — no manual Keychain work needed. If the session expires, the login window reappears.

## License

MIT License. Feel free to use Claude Pulse and contribute.
