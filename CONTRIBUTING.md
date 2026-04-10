# Contributing to Claude Pulse

Thank you for considering contributing to Claude Pulse!

We welcome contributions of all kinds: bug reports, feature requests, documentation improvements, and code contributions.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How to Contribute](#how-to-contribute)
- [Development Guidelines](#development-guidelines)
- [Pull Request Process](#pull-request-process)
- [Release Process](#release-process)

## Code of Conduct

Please be respectful, inclusive, and considerate in all interactions.

- Be welcoming and inclusive
- Be respectful of differing viewpoints
- Accept constructive criticism gracefully
- Focus on what's best for the community

## Getting Started

### Prerequisites

- **macOS 13.0+** (Ventura or later)
- **Xcode 26.4+**
- **Git**
- **A Claude AI account** for testing

### Development Setup

1. **Fork the repository**

   Click the "Fork" button on GitHub to create your own copy.

2. **Clone your fork**
   ```bash
   git clone https://github.com/YOUR_USERNAME/ClaudePulse.git
   cd ClaudePulse
   ```

3. **Add upstream remote**
   ```bash
   git remote add upstream https://github.com/sergey-zhuravel/ClaudePulse.git
   ```

4. **Open in Xcode**
   ```bash
   open "Claude Pulse.xcodeproj"
   ```
   Xcode will automatically resolve the Sparkle SPM dependency.

5. **Build and run**
   - Select the "Claude Pulse" scheme
   - Press `Cmd+R` to build and run
   - The app will appear in your menu bar

### Project Structure

```
Claude Pulse/
├── Claude_PulseApp.swift          # @main entry point, delegates to AppDelegate
├── AppDelegate.swift              # Status bar, popover, polling timer, Sparkle updater
├── Models/
│   └── QuotaSnapshot.swift        # Data model: usage counts, reset dates, computed labels
├── Services/
│   ├── UsageDataProvider.swift    # Core service: WKWebView scraping + API interception
│   └── AlertDispatcher.swift      # macOS notification dispatch on usage thresholds
├── Views/
│   ├── DashboardView.swift        # Main popover UI (header, bars, hints, footer)
│   ├── RingGaugeView.swift        # Circular progress indicator with gradient arc
│   └── HintCardView.swift         # Reusable tip card with copy-to-clipboard
├── Modules/
│   └── SignIn/
│       └── AuthWindowController.swift  # NSWindowController for claude.ai login
└── Resources/
    └── Assets.xcassets            # App icon, accent color, menu bar icon
```

## How to Contribute

### Reporting Bugs

Before submitting a bug report:
1. Check existing [issues](https://github.com/sergey-zhuravel/ClaudePulse/issues) to avoid duplicates
2. Ensure you're running the latest version

**When reporting a bug, include:**
- macOS version
- App version
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- Screenshots if applicable

### Suggesting Features

1. Check existing issues first
2. Describe the problem your feature would solve
3. Explain your proposed solution

### Contributing Code

1. **Find or create an issue** for what you want to work on
2. **Comment on the issue** to let others know you're working on it
3. **Fork and create a branch**
4. **Make your changes** following our [guidelines](#development-guidelines)
5. **Test thoroughly** on macOS 13.0+
6. **Submit a pull request**

## Development Guidelines

### Code Style

We follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).

**Key conventions:**

```swift
// Use MARK comments to organize code sections
// MARK: - Properties
// MARK: - Public API
// MARK: - Private Methods

// Use descriptive names
func reloadData()         // Good
func refresh()            // Too vague

// Prefer structs for data models
struct QuotaSnapshot { ... }

// Singletons use .instance pattern
static let instance = UsageDataProvider()
```

### Architecture

- **Models** (`Models/`): Value types, computed properties, no side effects
- **Services** (`Services/`): Singletons with `@Published` properties, Combine-based
- **Views** (`Views/`): SwiftUI structs, driven by `@EnvironmentObject` or closures
- **AppDelegate**: Coordinates services, manages status bar and popover

**Key patterns:**
- Services are `final class` with `private init()` and `.instance` singleton
- Data flows via Combine: `UsageDataProvider.$currentSnapshot` → AppDelegate → Views
- Web scraping uses JS injection (API interceptor + DOM fallback)
- No third-party dependencies except Sparkle 2 for auto-updates

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <description>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `chore`: Build process, dependencies, etc.

**Examples:**
```
feat: add Sonnet-only usage tracking
fix: show sign-in prompt when cookies are missing
docs: update SECURITY.md for v1.1
chore: bump version to 1.1
```

### Branch Naming

| Prefix | Use Case | Example |
|--------|----------|---------|
| `feat/` | New features | `feat/opus-usage-tracking` |
| `fix/` | Bug fixes | `fix/reset-label-not-showing` |
| `docs/` | Documentation | `docs/update-readme` |
| `chore/` | Maintenance | `chore/update-sparkle` |

## Pull Request Process

1. **Update your fork**
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Create your branch**
   ```bash
   git checkout -b feat/your-feature-name
   ```

3. **Make your changes and commit**

4. **Push to your fork**
   ```bash
   git push origin feat/your-feature-name
   ```

5. **Open a Pull Request**
   - Use a clear, descriptive title
   - Reference any related issues (`Closes #123`)
   - Describe what changes you made and why
   - Include screenshots for UI changes

**PR Checklist:**
- [ ] Code follows project style guidelines
- [ ] Self-reviewed my own code
- [ ] Tested on macOS 13.0+
- [ ] No new warnings in Xcode
- [ ] UI changes include screenshots

## Release Process

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Build Settings
2. Build & Archive in Xcode → Export → Notarize
3. Create DMG and sign with Sparkle's `sign_update`
4. Update `appcast.xml` with new version, signature, and length
5. Create GitHub Release with tag `vX.Y`, attach DMG
6. Push updated `appcast.xml` to main

---

Thank you for helping make Claude Pulse better!
