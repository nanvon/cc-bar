<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="cc-bar Logo">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">
  <b>macOS 原生菜单栏 AI 额度监控与本地用量看板</b><br>
  实时追踪 Codex、Claude Code、Antigravity、Cursor 与 Command Code 配额状态，精准分析本地会话 Token 与费用。
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/nanvon/cc-bar?color=brightgreen"></a>
  <img alt="Downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/total?color=blue">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-orange">
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest">下载安装</a> ·
  <a href="#-核心特性">功能特性</a> ·
  <a href="#-快速安装">安装指南</a> ·
  <a href="#-数据与隐私安全">安全说明</a> ·
  <a href="#-从源码构建">从源码构建</a> ·
  <a href="https://github.com/nanvon/cc-bar/issues">问题反馈</a> ·
  <a href="README_EN.md">English</a>
</p>

<p align="center">
  <img src="docs/Screenshots/popover-light.png" width="360" alt="Popover 总览 - 浅色模式">
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover 总览 - 深色模式">
</p>

---

## ✨ 核心特性

### ⚡ 多服务配额实时监控
* **全平台客户端覆盖** — 原生支持 5 大 AI 编程助手的配额查询与健康感知：
  * **Codex (OpenAI)**：5 小时主额度与周额度、重置倒计时；支持导入多个 Codex 账号同屏对比，展示额度到期时间与额外重置 Credits 次数。
  * **Claude Code (Anthropic)**：5 小时与周额度，支持专项模型（如 Fable）周额度细分；API 异常或凭据过期时支持安全的 CLI 兜底刷新。
  * **Antigravity (Google)**：Cloud Mode 直连云端 API（无需运行本地 IDE/CLI），权威分组展示 Gemini 5H 主额度、Gemini 周额度及 Claude 辅助额度。
  * **Cursor**：直连官方 Usage API，展示 Total 主额度、Auto 及 API 次要额度，自动识别 Unlimited 并呈现 `∞` 标识，精确汇总今日与本周真实费用。
  * **Command Code**：展示服务端返回的 5 小时主额度与周额度（上限与已用量均由接口给出），GOAT 套餐另附月度 Credits 额度（月总额 70）。
* **常驻菜单栏与 HUD 悬浮** — 菜单栏动态展示所选服务百分比（支持主要/周/双窗口模式）；独立桌面悬浮窗支持分服务开关、20pt 边缘自动吸附、位置记忆且不抢占键盘输入焦点。
* **实时可用性与智能调度** — Popover 动态滚动呈现最近刷新相对时间，内嵌 OpenAI、Anthropic 与 Cursor 官方服务健康状态点；后台额度（默认 2 分钟）、日志扫描（默认 5 分钟）与服务状态（固定 5 分钟）共用单一时基，到期任务合并唤醒，锁屏或息屏期间自动降频，系统睡眠时停表、唤醒后立即补刷；内置 60s 最小成功间隔与 429 后 10 分钟退避。

### 📊 本地用量与全维费用透视
* **跨引擎日志与远端计量聚合** — 自动解析本地 Codex（含 Standard/Fast 档位映射）、Claude Code（含 5m/1h 缓存 TTL 计价）、Pi（日志总价优先 + 价格表补齐）与 OpenCode（SQLite 库 `opencode.db`）会话记录，并接入 Cursor 全设备远端计量。
* **四大专业分析视图**：
  * **Overview（概览）**：统计粒度分日 / 周 / 月三档，时间范围随粒度切换（今天 / 本周 / 4 周 / 6 个月 / 全部 / 自定义等）；含总额与各服务 KPI 卡（带同期环比变化）、Token 拆分、按服务占比水平条、按粒度分桶的堆叠柱状图（单周期时自动扩展成近 14 个周期的上下文）、按模型与按提供商明细。
  * **Conversations（对话明细）**：深入单次对话，展示四项 Token（输入/输出/缓存创建/缓存读取）、缓存命中率、速度档位（`Fast` / `Mixed` 徽标）与 API 等值成本明细；无系统权限弹窗的安全智能项目归属识别。
  * **Cycles（周期用量）**：按 Codex / Claude 主账号真实重置窗口统计当前 5H / 周周期的本机消耗（2×2 宽卡网格），基于官方比例测算耗尽预估与重置倒计时。
  * **Timeline（额度时间线）**：5H 视图展示本地当天 00:00–24:00 的额度变动事件，周视图按服务返回的重置时刻划分当前与上一周期（不按自然周）；本机采样保留最近 15 天，多账号独立分区。
* **厂商提供商归并（ModelProvider）** — 跨客户端将模型智能归并在 OpenAI、Anthropic、DeepSeek、OpenCode-Go、Command Code 与其他 6 大面板下，支持按费用/Tokens/请求数/名称排序并就地展开 Token 拆分。

### 💻 纯净高效的原生体验
* **零配置自动识别** — 自动扫描本机既有登录态，涵盖 5 大服务的本地凭据，无需重复输入或保存任何第三方 API Key（亦支持 Command Code Keychain 手动配置）。
* **内置与双层在线价格引擎** — 内置价格表持续收录 Claude 5、GPT-5.6、DeepSeek、Cursor、Command Code 等最新模型；自动拉取 LiteLLM 与 models.dev 远端目录增量补齐，离线自动降级。
* **纯本地解析与注重隐私** — 对桌面、文稿、下载、音乐、图片、影片等受保护目录只做纯文本路径分词，零 macOS TCC 权限弹窗；会话仅提取 Token 与模型元数据，绝不读取聊天文本；支持隐私模式（隐藏邮箱/副账号名）与静默开机自启。
* **静态版本更新检测** — 基于 GitHub Release 静态版本清单检查更新，支持设置页手动一键检查，避免 GitHub API 速率限制。

---

### 📸 界面预览

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="用量统计 - 概览"><br>
  <sub><b>用量概览</b>：按服务与模型分类汇总 Token 消耗与费用走势</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="用量统计 - 对话"><br>
  <sub><b>会话明细</b>：下钻至单次对话的 Token 明细与成本分析</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-timeline.png" width="720" alt="用量统计 - 时间线"><br>
  <sub><b>额度时间线</b>：5 小时重置窗口内的额度消耗历史走势</sub>
</p>

---

## 📦 快速安装

> **运行环境**：macOS 14 (Sonoma) 或更新版本。<br>
> **前置条件**：相关 AI 编程工具需已在终端或桌面端完成至少一次登录。

1. 进入 [Releases 页面](https://github.com/nanvon/cc-bar/releases/latest) 下载最新的 `CCBar.dmg`（或 `CCBar.app.zip`）。
2. 打开 DMG，将 `CCBar.app` 拖入 `/Applications` 文件夹即可。

> [!NOTE]
> **首次启动安全提示 (Gatekeeper)**
>
> 发布的构建为 ad-hoc 签名（未走付费 Apple 公证）。首次启动若被系统拦截：
> 1. 打开 **系统设置 → 隐私与安全性**，向下滑动找到 CCBar 的拦截提示，点击 **「仍要打开」**；
> 2. 若系统提示「应用程序已损坏」，可在终端执行以下命令清除隔离标记：
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/CCBar.app
>    ```
> 3. 若本机不存在明文 credentials 文件，应用会在说明后请求 Keychain 读取权限，请选择 **「始终允许」**。

---

## 🔒 数据与隐私安全

cc-bar 严格遵循**本地优先与最小权限**原则，所有用量统计与额度查询均在本地完成：

### 凭据读取与刷新策略

| 服务 / 目标 | 凭据存储位置 | 读写权限 | 行为机制与安全保障 |
| :--- | :--- | :---: | :--- |
| **Codex** | `~/.codex/auth.json` | 读 / 写 | 临期时使用 `refresh_token` 自动续期。续期前二次确认本地文件，避免与 `codex` CLI 冲突抢刷。 |
| **Claude Code** | `~/.claude/.credentials.json`<br>或 macOS Keychain | **严格只读** | **绝不刷新或篡改凭据**。因 Anthropic 刷新令牌为一次性，第三方刷新会导致 CLI 被踢下线。过期时保留快照并提示终端重登；必要时提供安全 CLI 兜底。 |
| **Antigravity** | `~/.gemini/jetski-standalone-oauth-token`<br>`~/.gemini/oauth_creds.json` (兜底) | 读 / 写 | 优先读取独立 OAuth Token，临期自动续期回写。Cloud Mode 直连 Google 云端 API，无需本地 IDE 运行。 |
| **Cursor** | `~/Library/Application Support/Cursor`<br>`/User/globalStorage/state.vscdb` | **严格只读** | 仅读 `cursorAuth/accessToken` 构造 Cookie 查询用量，绝不碰 refresh token/OAuth，不写回 Cursor SQLite 或 Keychain。 |
| **Command Code** | 5 级本地来源或 macOS Keychain | 读 / Keychain | 只读自动探测按 `~/.commandcode/auth.json` → `~/.pi/agent/auth.json` → `~/.local/share/opencode/auth.json` → 环境变量 → Keychain 依次尝试；也可在设置中切换为手动 API Key，由 macOS Keychain 保存。 |
| **本地会话日志** | `~/.codex/sessions`、`~/.claude/projects`<br>`~/.pi/agent/sessions`、OpenCode SQLite | **严格只读** | 仅扫描本地 JSONL/SQLite 解析 Token 用量与模型元数据，绝不收集或上传聊天正文。受保护目录做纯文本路径分词，零权限弹窗。 |

### 系统权限与零遥测承诺
* **无受保护文件夹访问**：对桌面、文稿、下载、音乐、图片、影片等受保护目录，以及家目录以外的路径，项目归组仅做**纯文本路径分词**，绝不调用文件系统接口，因此**不会触发系统的隐私权限弹窗**。
* **零外部遥测**：全应用不包含任何统计上报或第三方 SDK，不发送任何用户行为遥测。

> [!TIP]
> 如果你对预编译二进制包有所顾虑，欢迎审阅完整源码并[从源码自主构建](#-从源码构建)。

---

## 🔧 从源码构建

需要完整版 Xcode（仅 Command Line Tools 无法构建 SwiftUI 资产）。

### 本地日常调试
在 Xcode 中打开 `ccbar.xcodeproj`，Scheme 选择 `ccbar`，目标设备选「My Mac」，按下 <kbd>⌘</kbd> + <kbd>R</kbd> 运行。

### 打包正式 Release
```bash
# 1. 确保命令行工具指向完整 Xcode (一次性)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 2. 执行本地打包脚本 (产物输出至 dist/ 目录)
./scripts/build.sh
```

构建脚本使用 `CODE_SIGNING_ALLOWED=NO` 编译并生成 ad-hoc 签名，产出的 `dist/CCBar.dmg` 与 `dist/CCBar.app.zip` 可在任意 Mac 机器上直接运行。

> [!WARNING]
> 请勿使用 Xcode 菜单中的 **Product → Archive** 导出分发，该方式会绑定个人开发证书，导致构建包无法在其他设备运行。

---

## 🔗 相关项目

同作者系列工具，共享同一套配额口径与设计语言：

| 项目 | 平台形态 | 技术栈 |
| :--- | :--- | :--- |
| **cc-bar**（本仓库） | macOS 原生菜单栏工具 | Swift / SwiftUI |
| [**CC Trace**](https://github.com/nanvon/cc-trace) | 桌面客户端（macOS 菜单栏 / Windows 托盘） | Tauri / Web |
| [**CC Trace Mobile**](https://github.com/nanvon/cc-trace-mobile) | 移动端伴侣（iOS / Android） | 移动端框架 |

---

## 🙏 致谢

在架构设计与额度解析思路上，本项目参考并汲取了以下开源项目的优秀经验：

* [cc-switch](https://github.com/farion1231/cc-switch) — 多 Provider 账号切换器，启发了多账号管理与切换流
* [cockpit-tools](https://github.com/jlcodes99/cockpit-tools) — 多平台 AI 辅助看板，在额度计算与刷新机制上提供了参考
* [CodexBar](https://github.com/steipete/CodexBar) — macOS 菜单栏用量监控，在本地日志解析与原生菜单栏交互上多有借鉴

---

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
