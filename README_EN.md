<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="cc-bar Logo">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">
  <b>macOS Native AI Quota Monitor & Usage Analytics</b><br>
  Monitor real-time quotas and reset countdowns for Codex, Claude Code, Cursor, and Antigravity in the menu bar; analyze tokens, costs, and conversations offline locally.
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/nanvon/cc-bar?color=brightgreen"></a>
  <img alt="Downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/total?color=blue">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="Latest Downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/latest/total?label=latest%20downloads&color=blue"></a>
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest">Download</a> ·
  <a href="#-service-support-matrix">Service Matrix</a> ·
  <a href="#-features">Features</a> ·
  <a href="#-data-and-privacy-security">Security</a> ·
  <a href="#-build-from-source">Build</a> ·
  <a href="https://github.com/nanvon/cc-bar/issues">Issues</a> ·
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/Screenshots/popover-light.png" width="360" alt="Popover Overview - Light Mode">
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover Overview - Dark Mode"><br>
  <sub>Menu bar, floating HUD, and Popover · Light / Dark mode</sub>
</p>

---

## ⚡ Service Support Matrix

cc-bar presents two types of data: **Subscription Quotas** queried directly from official APIs for remaining percentages and reset times; **Local Usage** parsed from local session logs or remote telemetry, never uploading code, project data, or conversation content.

| Service / Tool | Quota Monitoring | Alert Notifications | Local Usage / Cost Analytics | Multi-Account | Credential Source |
| :--- | :--- | :---: | :--- | :---: | :--- |
| **Codex** | 5h / weekly quotas, reset countdowns | Supported | Local sessions (incl. `.zst` logs) | Supported | `~/.codex/auth.json` (auto-renew) |
| **Claude Code** | 5h / weekly / model-specific quotas | Supported | Local session logs | — | Keychain / local read-only |
| **Antigravity** | Gemini 5h & weekly, Claude auxiliary | Supported | — | — | Google Cloud OAuth (auto-renew) |
| **Cursor** | Total / Auto / API (incl. Unlimited) | Supported | Remote metering (today / this cycle) | — | Local `state.vscdb` (read-only) |
| **Command Code** | 5h / weekly quotas, GOAT monthly Credits | Supported | — | — | 5-level auto-detection / Keychain Key |
| **OpenCode Go** | 5h / weekly / monthly quotas | Supported | — | — | OpenCode / Pi read-only detection / Keychain Key |
| **Pi / OpenCode / DSH** | — | — | Local sessions (Pi / OpenCode / DSH multi-frame zstd) | — | Strictly read-only local logs & DB |

---

## ✨ Features

### ⚡ Real-Time Quota & Status Monitoring
* **Menu Bar & Desktop Floating HUD** — Primary, weekly, or dual-window menu bar display. The HUD snaps to screen edges, remembers position, and does not steal keyboard focus.
* **Low Quota Notifications** — macOS system notifications when 5-hour, weekly, or billing cycle quotas drop below configured thresholds. Fires once per cycle; clicking opens usage analytics.
* **Low-Overhead Scheduling** — Quota queries, log scanning, and service status tasks share a schedule; slows down on screen lock, pauses during sleep, refreshes on wake, and backs off on HTTP 429.
* **Seamless Multi-Account Support** — Paste `auth.json` or PAT into Codex to monitor multiple accounts side-by-side with quota expiration and available reset credits, without affecting CLI sign-in.

### 📊 Local Offline Usage & Project Analytics
* **Multi-Dimensional Analytics** — Four pages (Overview, Conversations, Projects, Quota) with day / week / month granularity and custom date ranges:
  * **Overview**: Stacked charts for total tokens, costs, and period-over-period changes; breakdown by service, provider, model, or project; cache hit rates.
  * **Conversations**: Search past sessions, view input, output, cache read/write breakdowns, request counts, models, and Standard / Fast speed tier cost splits.
  * **Projects**: Project-level usage trends, top conversations, and branch distributions; recognized Git worktrees roll up into the main repository.
  * **Quota Comparison & Projections**: Compare current cycle local usage, projected usage, and official quota usage percentages; optionally include Codex subscription usage from Pi, OpenCode, and DSH.
* **Automatic Recalculation on Rule Changes** — History is automatically re-priced when pricing or accounting rules change; usage from cleaned-up source logs is preserved.

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="Usage Overview">
</p>

<details>
  <summary><b>View screenshots for Conversations, Projects, and Quota</b></summary>
  <br>
  <p align="center">
    <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="Conversation Details"><br><br>
    <img src="docs/Screenshots/statistics-projects.png" width="720" alt="Project Analytics"><br><br>
    <img src="docs/Screenshots/statistics-quota.png" width="720" alt="Quota Monitoring">
  </p>
</details>

### 💻 Native Experience & Privacy Controls
* **Single-Page Management & Drag Reordering** — Toggle all services on one page in Settings → Services & Accounts; drag rows to customize global order across the menu bar, popover, HUD, and statistics.
* **Screenshot Privacy Mode** — One-click redaction of account emails, paths, branches, and session IDs while preserving real amounts, tokens, and charts for safe sharing.
* **Seamless In-App Updates** — Built-in Sparkle updater to view release notes, download, install, and automatically restart.
* **Local Diagnostics & Zero Telemetry** — Automatic log rotation with redacted sensitive fields; export diagnostic bundles locally with zero user behavior telemetry.

<p align="center">
  <img src="docs/Screenshots/settings.png" width="720" alt="Services & Accounts">
</p>

---

## 📦 Installation

> **System Requirement**: macOS 14 (Sonoma) or later.<br>
> **Prerequisites**: Relevant AI coding tools must be logged in at least once via their respective CLIs or desktop apps.

1. Download the latest `CCBar.dmg` (or `CCBar.app.zip`) from the [Releases page](https://github.com/nanvon/cc-bar/releases/latest).
2. Open the DMG image and drag `CCBar.app` into your `/Applications` directory.

Upgrading to a version with the in-app updater for the first time requires manual installation as described above. Subsequent updates can be viewed under Settings → General → Check for Updates, and installed automatically with restart by clicking "Download and Install".

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
| **Antigravity** | System Keychain `gemini / antigravity` (preferred)<br>Legacy jetski / CLI token / oauth_creds files | GUI credentials: read-only; CCBar refresh cache: read/write; legacy jetski / oauth_creds: read/write | Desktop-app sign-in supports account detection, cloud quotas, and automatic renewal without agy. Refreshed credentials are bound to the original login and stored in CCBar’s own Keychain. |
| **Cursor** | `~/Library/Application Support/Cursor`<br>`/User/globalStorage/state.vscdb` | **Strictly Read-Only** | Reads only `cursorAuth/accessToken` to construct session cookies for usage queries. Never touches refresh tokens/OAuth and never writes back to SQLite or Keychain. |
| **Command Code** | 5-level local sources or macOS Keychain | Read / Keychain | Read-only auto-detection in order: `~/.commandcode/auth.json` → `~/.pi/agent/auth.json` → `~/.local/share/opencode/auth.json` → environment variables → Keychain. Settings can also switch to a manual API key stored in the macOS Keychain. |
| **OpenCode Go** | OpenCode / Pi `auth.json` or macOS Keychain | Read / Keychain | Read-only auto-detection in order: OpenCode `auth.json` → `~/.pi/agent/auth.json` → `OPENCODE_API_KEY` → Keychain, using the `opencode-go` API key. Settings can also switch to a manual API key stored in the macOS Keychain. |
| **Local Session Logs** | `~/.codex/sessions`, `~/.claude/projects`<br>`~/.pi/agent/sessions`, OpenCode SQLite<br>`~/.dsh/sessions` | **Strictly Read-Only** | Parses usage, model, and project metadata, and reads title indexes or extracts conversation titles from logs. Missing titles may use a user-message excerpt. No conversation content is uploaded and source logs are never modified. |

### System Permissions & Zero Telemetry Commitment
* **No Protected Directory Access**: For Desktop, Documents, Downloads, Music, Pictures, Movies, and paths outside the home directory, project grouping uses **pure text path tokenization** without filesystem APIs, **never triggering macOS permission prompts**.
* **Zero External Telemetry**: No user tracking or behavioral telemetry is collected or reported; Sparkle only checks and downloads signed releases.
* **Screenshot Privacy & Local Data**: Privacy Mode only obfuscates identities in the UI; real titles, paths, and statistics stay local on your machine.
* **Diagnostics Stay Local**: Logs are written to `~/Library/Logs/CCBar/` (~8 MB cap, auto-rotating) and redacted by default — no auth tokens, plaintext emails, conversation contents, file contents, or project names. Accounts appear only as one-way hashes.

> [!TIP]
> If you have concerns about pre-compiled binaries, you are welcome to inspect the source code and [build from source](#-build-from-source).

> [!NOTE]
> **Reporting Issues**: Open Settings → General → Diagnostics → Export Diagnostic Logs. After confirmation, a zip bundle will be revealed in Finder; attach it to an [Issue](https://github.com/nanvon/cc-bar/issues). `summary.txt` inside the bundle is plaintext for easy review before sending.

---

## 🔧 Build from Source

Requires full Xcode installation (Command Line Tools alone cannot compile SwiftUI asset catalogs).

### Local Debugging
Open `ccbar.xcodeproj` in Xcode, select the `ccbar` scheme, choose "My Mac" as the target destination, and press <kbd>⌘</kbd> + <kbd>R</kbd> to run.

### Building a Release Package
```bash
# 1. Ensure command line tools point to full Xcode (one-time)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 2. Run the local packaging script (outputs to dist/)
SPARKLE_PUBLIC_ED_KEY="your_public_ed_key" ./scripts/build.sh
```

Before building, set up `SPARKLE_PUBLIC_ED_KEY` according to [Release Guide](docs/打包发布.md#首次配置更新签名密钥). The build script compiles with `CODE_SIGNING_ALLOWED=NO` and applies multi-layer ad-hoc code signatures, producing `dist/CCBar.dmg` and `dist/CCBar.app.zip`.

> [!WARNING]
> Do not use **Product → Archive** in Xcode to distribute builds; doing so binds your personal developer certificate and prevents the app from running on other machines.

---

## 🔗 Related Projects

Tools by the same author sharing the same quota calculation logic and design language:

| Project | Platform | Tech Stack |
| :--- | :--- | :--- |
| **cc-bar** (This Repo) | macOS Native Menu Bar Tool | Swift / SwiftUI |
| [**CC Trace**](https://github.com/nanvon/cc-trace) | Desktop Client (macOS Menu Bar / Windows Tray) | Tauri / Web |
| [**CC Trace Mobile**](https://github.com/nanvon/cc-trace-mobile) | Mobile Companion (iOS / Android) | Mobile Framework |

---

## 🙏 Acknowledgments

Architectural concepts and quota parsing strategies reference and build upon these great open-source projects:

* [cc-switch](https://github.com/farion1231/cc-switch) — Multi-provider account switcher; inspired the multi-account management flow.
* [cockpit-tools](https://github.com/jlcodes99/cockpit-tools) — Multi-platform AI assistant dashboard; referenced for quota polling and refresh strategies.
* [CodexBar](https://github.com/steipete/CodexBar) — macOS menu bar AI usage monitor; referenced for local log parsing and menu bar interactions.

Thanks to the [LINUX DO](https://linux.do/) community for the discussions and feedback.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
