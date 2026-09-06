<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="cc-bar Logo">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">
  <b>Native macOS Menu Bar AI Quota Monitor & Local Usage Dashboard</b><br>
  Real-time remaining quotas for Codex, Claude Code, Antigravity, Cursor, and Command Code, with granular local token & cost analytics.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/nanvon/cc-bar?color=brightgreen"></a>
  <img alt="Downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/total?color=blue">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-orange">
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest">Download</a> ·
  <a href="#-features">Features</a> ·
  <a href="#-installation">Install</a> ·
  <a href="#-data-and-privacy-security">Security</a> ·
  <a href="#-building-from-source">Build from Source</a> ·
  <a href="https://github.com/nanvon/cc-bar/issues">Feedback</a> ·
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/Screenshots/popover-light.png" width="360" alt="Popover Overview - Light Mode">
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover Overview - Dark Mode">
</p>

---

## ✨ Features

### ⚡ Real-Time Multi-Service Quota Monitoring
* **Comprehensive AI Assistant Support** — Native quota tracking and health awareness across 5 major AI coding companions:
  * **Codex (OpenAI)**: 5-hour primary and weekly quotas with reset countdowns; import multiple Codex accounts side-by-side with expiration dates and bonus reset credits.
  * **Claude Code (Anthropic)**: 5-hour and weekly quotas with specialized model (e.g. Fable) weekly allocations; transparent, safe CLI fallback refresh on API errors or expired credentials.
  * **Antigravity (Google)**: Cloud Mode direct connection to Google Cloud APIs (without requiring local IDE/CLI processes), grouping Gemini 5H, Gemini Weekly, and Claude auxiliary quotas.
  * **Cursor**: Direct connection to the official Usage API, displaying Total primary quota alongside Auto and API breakdown, automatically recognizing Unlimited with `∞` badges and aggregating today/week actual spend.
  * **Command Code**: Shows the 5-hour primary and weekly quotas returned by the service (both cap and usage come from the API), plus monthly GOAT subscription Credits (monthly allowance 70).
* **Menu Bar & Floating HUD** — Customizable menu bar percentages (primary, weekly, or both); independent desktop HUD overlay with per-service toggles, 20pt edge magnetic snapping, position persistence, and non-activating window behavior (never steals keyboard focus).
* **Live Health & Smart Scheduling** — Dynamic relative timestamp ("refreshed Xs ago") rolling in the Popover header; embedded live health status dots for OpenAI, Anthropic and Cursor; quota polling (2 min by default), log scanning (5 min by default) and service status (fixed 5 min) share a single time base so due jobs wake up together, throttle down while the screen is locked or asleep, stop the clock during system sleep and refresh immediately on wake; 60s minimum interval between successes and a 10-minute backoff after a 429.

### 📊 Local Usage & Cost Analytics
* **Cross-Engine Log & Remote Metering Aggregation** — Automatically parses local session logs across Codex (with Standard/Fast tier mapping), Claude Code (with 5m/1h cache TTL differentiation), Pi (log total cost priority + catalog fallback), and OpenCode (`opencode.db` SQLite), combined with Cursor full-device remote metering.
* **Four Dedicated Analytics Views**:
  * **Overview**: Day / week / month granularity with the time range following the selected granularity (Today, This week, 4w, 6m, All, Custom, …); total and per-service KPI cards with period-over-period delta, token breakdown, horizontal service distribution bars, a stacked bar chart bucketed by granularity (a single-period range expands into a 14-period context window), plus by-model and by-provider breakdowns.
  * **Conversations**: Drill down into individual chats with 4-way token breakdown (input, output, cache creation, cache read), cache hit ratios, execution speed indicators (`Fast` / `Mixed` badges), and API-equivalent cost estimations; secure project grouping without macOS permission prompts.
  * **Cycles**: 2×2 grid tracking local token and cost consumption within Codex and Claude primary accounts' actual 5-hour and weekly reset windows, projecting burn-out time and reset countdowns based on official quota ratios.
  * **Timeline**: The 5H view shows quota change events for the local day (00:00–24:00); the weekly view splits the current and previous cycle by the reset time the service reports, not by calendar week. Local samples are kept for 15 days, with one section per account.
* **Model Provider Grouping (ModelProvider)** — Automatically classifies models across tools into 6 dedicated provider panels: OpenAI, Anthropic, DeepSeek, OpenCode-Go, Command Code, and Other; supports sorting by cost, tokens, requests, or name, with inline token breakdowns.

### 💻 Pure Native Experience
* **Zero-Config Onboarding** — Auto-detects existing local CLI and desktop sessions across all 5 services without re-entering or managing third-party API keys (also supports manual Keychain API key configuration for Command Code).
* **Built-in & Dual Remote Pricing Engine** — Built-in catalog continually updated with latest models including Claude 5, GPT-5.6, DeepSeek, Cursor, and Command Code; automatically syncs and caches upstream LiteLLM and models.dev catalogs with graceful offline fallback.
* **Privacy-First Local Parsing** — Safe string-only path splitting for protected directories (Desktop, Documents, Downloads, Music, Pictures, Movies), completely eliminating macOS TCC privacy permission dialogs; parses only tokens and model metadata without touching chat text; includes privacy mode (masks email and account names) and silent launch-at-login.
* **Static Version Update Checker** — Checks updates against static GitHub Release manifests to eliminate GitHub API rate limits, with manual one-click checks in Settings.

---

### 📸 Screenshots

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="Usage Statistics - Overview"><br>
  <sub><b>Usage Overview</b>: Token consumption and cost trends categorized by service and model</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="Usage Statistics - Conversations"><br>
  <sub><b>Conversation Drilldown</b>: Per-session token breakdowns and cost analysis</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-timeline.png" width="720" alt="Usage Statistics - Timeline"><br>
  <sub><b>Quota Timeline</b>: Historical quota burn rates within 5-hour reset windows</sub>
</p>

---

## 📦 Installation

> **System Requirement**: macOS 14 (Sonoma) or later.<br>
> **Prerequisites**: Relevant AI coding tools must be logged in at least once via their respective CLIs or desktop apps.

1. Download the latest `CCBar.dmg` (or `CCBar.app.zip`) from the [Releases page](https://github.com/nanvon/cc-bar/releases/latest).
2. Open the DMG image and drag `CCBar.app` into your `/Applications` directory.

> [!NOTE]
> **First-Launch Gatekeeper Notice**
>
> Published builds are ad-hoc signed (without paid Apple notarization). If blocked by macOS Gatekeeper on first launch:
> 1. Open **System Settings → Privacy & Security**, scroll down to find the CCBar notification, and click **"Open Anyway"**;
> 2. If macOS reports that the app "is damaged", remove the quarantine attribute manually via Terminal:
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/CCBar.app
>    ```
> 3. If no plain-text credentials file exists, the app will request Keychain read permission with an explanation dialog — please select **"Always Allow"**.

---

## 🔒 Data and Privacy Security

cc-bar strictly adheres to **local-first and least-privilege** principles. All usage metrics and quota queries are executed entirely on your machine:

### Credential Reading & Refresh Policy

| Service / Tool | Credential Path | Access Mode | Behavior & Security Guarantees |
| :--- | :--- | :---: | :--- |
| **Codex** | `~/.codex/auth.json` | Read / Write | Automatically renews tokens via `refresh_token` near expiry. Re-reads the file before renewing to prevent race conditions with the `codex` CLI. |
| **Claude Code** | `~/.claude/.credentials.json`<br>or macOS Keychain | **Strictly Read-Only** | **Never refreshes or writes credentials**. Anthropic refresh tokens are single-use; third-party rotation invalidates CLI sessions. Preserves the last snapshot and prompts for CLI re-login when expired; provides safe CLI fallback when needed. |
| **Antigravity** | `~/.gemini/jetski-standalone-oauth-token`<br>`~/.gemini/oauth_creds.json` (fallback) | Read / Write | Reads the standalone OAuth token first and refreshes near expiry. Cloud Mode queries Google Cloud APIs directly without requiring local IDE processes. |
| **Cursor** | `~/Library/Application Support/Cursor`<br>`/User/globalStorage/state.vscdb` | **Strictly Read-Only** | Reads only `cursorAuth/accessToken` to construct session cookies for usage queries. Never touches refresh tokens/OAuth and never writes back to SQLite or Keychain. |
| **Command Code** | 5-level local sources or macOS Keychain | Read / Keychain | Read-only auto-detection in order: `~/.commandcode/auth.json` → `~/.pi/agent/auth.json` → `~/.local/share/opencode/auth.json` → environment variables → Keychain. Settings can also switch to a manual API key stored in the macOS Keychain. |
| **Local Session Logs** | `~/.codex/sessions`, `~/.claude/projects`<br>`~/.pi/agent/sessions`, OpenCode SQLite | **Strictly Read-Only** | Parses local JSONL / SQLite files for token metrics and model metadata only. Never reads or uploads conversation text. Safe path tokenization prevents permission prompts. |

### System Permissions & Zero-Telemetry Guarantee
* **Zero Protected-Folder Access**: For protected directories (Desktop, Documents, Downloads, Music, Pictures, Movies) and for any path outside the home directory, project grouping relies exclusively on **in-memory string splitting**. It never invokes filesystem APIs on those paths, avoiding macOS privacy permission prompts.
* **No Telemetry**: Contains zero tracking SDKs, analytics libraries, or external reporting services.

> [!TIP]
> If you prefer not to run pre-compiled binaries, you are encouraged to audit the source code and [build from source](#-building-from-source).

---

## 🔧 Building from Source

Requires the full Xcode suite (Command Line Tools alone cannot compile SwiftUI asset catalogs).

### Local Development & Debugging
Open `ccbar.xcodeproj` in Xcode, select the `ccbar` scheme with destination "My Mac", and press <kbd>⌘</kbd> + <kbd>R</kbd> to run.

### Release Packaging
```bash
# 1. Point command line tools to the full Xcode installation (one-time)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 2. Run the local build script (outputs artifacts to dist/)
./scripts/build.sh
```

The script builds with `CODE_SIGNING_ALLOWED=NO` and produces an ad-hoc signed bundle. The resulting `dist/CCBar.dmg` and `dist/CCBar.app.zip` can run on any Mac.

> [!WARNING]
> Do not distribute using Xcode's **Product → Archive** export, as it attaches a personal developer certificate that prevents execution on other devices.

---

## 🔗 Related Projects

Part of the same tool series by the author, sharing quota definitions and design language:

| Project | Platform Form Factor | Tech Stack |
| :--- | :--- | :--- |
| **cc-bar** (this repository) | Native macOS menu bar utility | Swift / SwiftUI |
| [**CC Trace**](https://github.com/nanvon/cc-trace) | Desktop client (macOS menu bar / Windows tray) | Tauri / Web |
| [**CC Trace Mobile**](https://github.com/nanvon/cc-trace-mobile) | Mobile companion (iOS / Android) | Mobile Framework |

---

## 🙏 Acknowledgments

Architectural concepts and quota parsing strategies reference and build upon these great open-source projects:

* [cc-switch](https://github.com/farion1231/cc-switch) — Multi-provider account switcher; inspired the multi-account management flow.
* [cockpit-tools](https://github.com/jlcodes99/cockpit-tools) — Multi-platform AI assistant dashboard; referenced for quota polling and refresh strategies.
* [CodexBar](https://github.com/steipete/CodexBar) — macOS menu bar AI usage monitor; referenced for local log parsing and menu bar interactions.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
