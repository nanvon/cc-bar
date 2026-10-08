<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="cc-bar Logo">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">
  <b>Native macOS AI Quota Monitor & Usage Analytics</b><br>
  View remaining quotas in the menu bar and analyze tokens, costs, and cache usage by conversation, project, and model.
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
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover Overview - Dark Mode"><br>
  <sub>Menu bar, floating HUD, and Popover · Light / Dark mode</sub>
</p>

---

## ✨ Features

### ⚡ Multi-Service Quota Monitoring

* **Five quota services** — Codex, Claude Code, Antigravity, Cursor, and Command Code:
  * **Codex**: 5-hour and weekly quotas with reset countdowns. Paste `auth.json` to view additional accounts side by side, including quota expiration and available reset credits, without switching the CLI sign-in.
  * **Claude Code**: 5-hour, weekly, and model-specific quotas. Manual refresh can use a CLI fallback when the API fails and no cached quota is available.
  * **Antigravity**: Direct cloud API queries without a running local IDE, showing Gemini 5-hour and weekly quotas plus Claude auxiliary quotas.
  * **Cursor**: Total, Auto, and API quotas with Unlimited detection, plus today's and this week's remotely metered costs.
  * **Command Code**: 5-hour and weekly quotas, plus monthly Credits for GOAT plans. Automatically detect credentials or store a manual API key in Keychain.
* **Menu bar and floating HUD** — Choose services independently, with primary, weekly, or dual-window menu bar display. The HUD remembers its position, snaps to screen edges, and does not steal keyboard focus.
* **Background refresh and service status** — Official service status and relative refresh times. Quota, log, and status tasks share a schedule, slow down while the screen is locked or asleep, pause during system sleep, and refresh on wake. Failed requests preserve cached data; 429 responses trigger backoff.

### 📊 Usage, Conversations, and Project Analytics

* **Five local sources plus Cursor remote metering** — Read local sessions from Codex, Claude Code, Pi, OpenCode, and DSH (DeepSeek Harness). DSH supports JSONL and zstd-compressed logs. Cursor usage covers the account across devices through remote metering. Antigravity and Command Code provide quotas without separate usage analytics sources.
* **Four analytics pages** — Overview, Conversations, and Projects share day / week / month granularity, time ranges, and custom dates:
  * **Overview**: Total tokens, costs, per-service costs, and changes from the previous period; stacked usage charts, token breakdowns, and cache hit rate. Switch usage composition between service, provider, model, and project, or open a top conversation directly. Usage composition, top conversations, and project rankings sort by tokens by default; switch to cost in Settings → Appearance & Display → Statistics. A single-period selection expands the daily chart to 30 days, or weekly / monthly charts to 14 periods; totals still cover only the selected range.
  * **Conversations**: Filter by service or project, search titles or projects, and sort by recent activity, tokens, or cost. Details cover the conversation's entire history: input, output, cache writes and reads, requests, cache hit rate, models, Standard / Fast tiers, and cost breakdowns.
  * **Projects**: Tokens, costs, conversation counts, and active days by project, with daily trends, tools and models, branches, and top conversations. Recognized Git worktrees roll up into their main repository, with individual worktree details. Cursor remote usage, backfills, and early daily-only history appear separately as Unattributed.
  * **Quota**: Current Codex and Claude Code 5-hour / weekly local usage, projected full-quota usage, official quota usage percentages, and reset countdowns on one page. Quota history below shows today in the 5-hour view, or the current and previous cycles based on official reset times in the weekly view, with separate sections for each account.
* **Cost estimates and pricing** — Local costs use recorded log costs or model-based estimates to compare consumption; they are not subscription bills. Cursor uses service-side metered costs. Pricing supports Codex Standard / Fast and long-context tiers, Claude cache TTLs and advisor usage. The built-in catalog includes GPT-6.1 Sol, Claude Haiku 5.5, DeepSeek, Gemini, GLM, MiniMax, and Command Code model variants, supplemented by LiteLLM / models.dev. Price updates do not reprice history automatically; use Recalculate usage in Settings.
* **History protection and verified recalculation** — Daily totals, conversations, cycle usage, and scan progress are saved together. A damaged current snapshot can fall back to the previous complete snapshot. Recalculation checks against preserved history first; incomplete reads, usage mismatches, or save failures retain the original data and display a warning. Incomplete results from cleaned-up source logs do not directly overwrite history.

### 💻 Native Interface and Settings

* **Services & Accounts** — Every service on one page: detected and not-yet-detected services are listed separately with setup hints, each with a single switch for both quota and usage plus menu bar and floating HUD checkboxes. Refresh failures are flagged inline, and each row's info button shows its data sources. Turning a service off preserves scanning and history so it remains available when turned back on. Codex and Claude Code are on by default, and Antigravity turns on when a sign-in is detected; Cursor, Command Code, and the floating HUD are off until you enable them in Settings.
* **Screenshot privacy mode** — Anonymize accounts, projects, and conversations; hide paths, branches, and IDs across analytics, the Popover, account settings, and related hints. Real costs, tokens, models, dates, and charts remain visible; original data is unchanged. Off by default; enable it in Settings → Appearance & Display → Privacy mode.
* **Native macOS experience** — Light / dark appearance, Chinese / English, silent launch at login, keyboard refresh, and manual or startup checks for GitHub Release updates.
* **Local diagnostics** — Logs rotate automatically and are redacted by default. Export a diagnostic bundle in Settings to inspect and share yourself; the app never uploads it automatically.

---

### 📸 Screenshots

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="Usage Overview"><br>
  <sub><b>Usage Overview</b>: Tokens and costs by time range, with usage trends, cache hit rate, usage composition, and top conversations</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="Conversation Details"><br>
  <sub><b>Conversation Details</b>: Search or filter conversations by project, then inspect token breakdowns, estimated costs, models, and speed tiers</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-projects.png" width="720" alt="Project Analytics"><br>
  <sub><b>Project Analytics</b>: Usage and costs by project, with daily trends, tools and models, branches, and top conversations</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-quota.png" width="720" alt="Quota Monitoring"><br>
  <sub><b>Quota Monitoring</b>: Current 5-hour and weekly usage for Codex and Claude Code, with official quota usage percentages and quota change history</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/settings.png" width="720" alt="Services & Accounts"><br>
  <sub><b>Services & Accounts</b>: Turn services on, choose menu bar and floating HUD, and add more Codex accounts under Codex</sub>
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

Usage logs are parsed and stored locally. Quotas, Cursor remote metering, service status, and pricing catalogs are fetched through their respective network APIs. The app does not upload local session logs or project data.

### Credential Reading & Refresh Policy

| Service / Tool | Credential Path | Access Mode | Behavior & Security Guarantees |
| :--- | :--- | :---: | :--- |
| **Codex** | `~/.codex/auth.json`<br>Imported accounts: CCBar's own Keychain items | Read / Write | Automatically renews tokens via `refresh_token` near expiry and writes new tokens back to where they came from. Re-reads the file before renewing to prevent race conditions with the `codex` CLI. |
| **Claude Code** | `~/.claude/.credentials.json`<br>or macOS Keychain | **Strictly Read-Only** | **Never refreshes or writes credentials**. Anthropic refresh tokens are single-use; third-party rotation invalidates CLI sessions. Preserves the last snapshot and prompts for CLI re-login when expired; provides safe CLI fallback when needed. |
| **Antigravity** | `~/.gemini/jetski-standalone-oauth-token`<br>`~/.gemini/oauth_creds.json` (fallback) | Read / Write | Reads the standalone OAuth token first and refreshes near expiry. Cloud Mode queries Google Cloud APIs directly without requiring local IDE processes. |
| **Cursor** | `~/Library/Application Support/Cursor`<br>`/User/globalStorage/state.vscdb` | **Strictly Read-Only** | Reads only `cursorAuth/accessToken` to construct session cookies for usage queries. Never touches refresh tokens/OAuth and never writes back to SQLite or Keychain. |
| **Command Code** | 5-level local sources or macOS Keychain | Read / Keychain | Read-only auto-detection in order: `~/.commandcode/auth.json` → `~/.pi/agent/auth.json` → `~/.local/share/opencode/auth.json` → environment variables → Keychain. Settings can also switch to a manual API key stored in the macOS Keychain. |
| **Local Session Logs** | `~/.codex/sessions`, `~/.claude/projects`<br>`~/.pi/agent/sessions`, OpenCode SQLite<br>`~/.dsh/sessions` | **Strictly Read-Only** | Parses usage, model, and project metadata, and reads title indexes or extracts conversation titles from logs. Missing titles may use a user-message excerpt. No conversation content is uploaded and source logs are never modified. |

### System Permissions & Zero-Telemetry Guarantee
* **Zero Protected-Folder Access**: For protected directories (Desktop, Documents, Downloads, Music, Pictures, Movies) and for any path outside the home directory, project grouping relies exclusively on **in-memory string splitting**. It never invokes filesystem APIs on those paths, avoiding macOS privacy permission prompts.
* **No Telemetry**: Contains zero tracking SDKs, analytics libraries, or external reporting services.
* **Screenshot privacy and local data**: Privacy mode hides identities in the interface; real titles, paths, and statistics remain stored locally. Review screenshots before sharing, and check exported files and clipboard contents separately.
* **Diagnostic Logs Stay Local**: Runtime logs live in `~/Library/Logs/CCBar/` (rotated, capped at roughly 8 MB) and are redacted by default — no sign-in tokens, plain-text email addresses, conversation content, file contents, or project names; accounts appear only as one-way hashes. Nothing is ever uploaded.

> [!TIP]
> If you prefer not to run pre-compiled binaries, you are encouraged to audit the source code and [build from source](#-building-from-source).

> [!NOTE]
> **Reporting a problem**: open Settings → General → Diagnostics → Export diagnostics. After you confirm the disclosure, a zip is created and revealed in Finder — attach it to an [Issue](https://github.com/nanvon/cc-bar/issues). The `summary.txt` inside is plain text, so you can read it yourself before sending.

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
