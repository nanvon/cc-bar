<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="cc-bar Logo">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">
  <b>macOS 原生 AI 额度监控与用量分析工具</b><br>
  在菜单栏查看多服务剩余额度，按对话、项目和模型分析 Tokens、费用与缓存使用。
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
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover 总览 - 深色模式"><br>
  <sub>菜单栏、桌面悬浮窗与 Popover · 浅色 / 深色模式</sub>
</p>

---

## ✨ 核心特性

### ⚡ 多服务额度监控

* **五种额度服务** — 支持 Codex、Claude Code、Antigravity、Cursor 和 Command Code：
  * **Codex**：5 小时与周额度、重置倒计时；支持粘贴 `auth.json` 导入多个账号同屏查看，查看额度到期时间及可用的额外重置次数，不切换 CLI 登录状态。
  * **Claude Code**：5 小时、周额度与模型专项额度；API 失败且无可展示缓存时，手动刷新可使用 CLI 兜底。
  * **Antigravity**：直接查询云端 API，无需运行本地 IDE；展示 Gemini 5 小时、周额度及 Claude 辅助额度。
  * **Cursor**：展示 Total、Auto 与 API 额度，识别 Unlimited，并汇总今日与本周的远端计量费用。
  * **Command Code**：展示 5 小时与周额度，GOAT 套餐附月度 Credits；支持自动探测凭据或在 Keychain 中保存手动 API Key。
* **菜单栏与桌面悬浮窗** — 分服务选择显示内容，菜单栏支持主要 / 周 / 双窗口模式；悬浮窗支持边缘吸附、位置记忆，不抢占键盘焦点。
* **后台刷新与服务状态** — 展示官方服务状态和最近刷新时间；额度、日志与服务状态任务合并调度，锁屏或息屏时降频，睡眠时暂停、唤醒后补刷。网络失败保留已有快照，429 后遵守退避。

### 📊 用量、对话与项目分析

* **五种本地数据源与 Cursor 远端计量** — 读取 Codex、Claude Code、Pi、OpenCode 和 DSH（DeepSeek Harness）的本机会话记录；DSH 支持 JSONL 与 zstd 压缩日志。Cursor 用量来自账号全设备远端计量。Antigravity 与 Command Code 提供额度展示，不作为独立用量统计来源。
* **四个统计页面** — 概览、对话与项目共享日 / 周 / 月粒度、时间范围及自定义日期：
  * **概览**：总 Tokens、费用、各服务费用与同期变化；堆叠用量图、Token 拆分与缓存命中率。用量构成可按服务、提供商、模型或项目切换，高消耗对话可直接跳转到详情。用量构成、高消耗对话和项目排行默认按 Tokens 排序，可在「设置 → 外观与显示 → 统计」改为按费用。选择单个周期时，日图扩展为近 30 天，周 / 月图扩展为近 14 个周期，汇总仍只统计所选范围。
  * **对话**：按服务、项目筛选，搜索标题或项目，按最近活动、Tokens 或费用排序。详情展示对话全部时间的输入、输出、缓存写入与读取、请求数、缓存命中率、模型构成，以及 Standard / Fast 档位和费用拆分。
  * **项目**：按项目汇总 Tokens、费用、对话数与活跃天数，查看每日趋势、工具与模型、分支和高消耗对话；可识别的 Git worktree 自动归入主仓库，并展示各 worktree 的明细。Cursor 远端计量、补录与早期按天汇总历史单列为「未归属」。
  * **额度**：在同一页查看 Codex 与 Claude Code 当前 5 小时 / 周周期的本机用量、用满预估、官方已用比例和重置倒计时。下方展示额度变化：5 小时视图看今天，周视图按官方重置时刻展示当前与上一额度周期；多账号独立展示。
* **费用口径与定价** — 本地费用按日志记录或模型价格估算，用于比较消耗，不等同于订阅账单；Cursor 使用服务端计量费用。支持 Codex Standard / Fast、长上下文阶梯、Claude 缓存 TTL 与 advisor 用量；内置价格表包含 GPT-6.1 Sol、Claude Haiku 5.5、DeepSeek、Gemini、GLM、MiniMax 及 Command Code 的模型变体，并通过 LiteLLM / models.dev 补齐。价格或统计规则变化后自动重算历史费用，日志已删除的对话保留用量。
* **历史保护与安全重算** — 日统计、对话、周期用量及扫描进度统一保存，当前快照损坏时尝试恢复上一份完整快照。重算以现有日志为准，源日志已清理的对话保留原用量；日志读取不完整或保存失败时保留原数据并提示。

### 💻 原生界面与设置

* **服务与账号** — 一页设置完所有服务：检测到的服务和未检测到的分开列出并给出接入提示，每个服务一个开关同时管额度和用量，并可直接勾选是否显示在菜单栏和悬浮窗；刷新失败会在行内标出，点行尾按钮可查看数据来源。关闭服务后仍保留扫描和历史，重新开启可继续查看。Codex 与 Claude Code 默认开启，Antigravity 检测到登录后默认开启；Cursor、Command Code 与桌面悬浮窗默认关闭，需在设置中手动开启。
* **截图隐私模式** — 匿名显示账号、项目与对话，遮挡路径、分支和 ID，覆盖统计页、Popover、账号设置及相关提示；保留真实金额、Tokens、模型、时间与图表，不修改原始数据。默认关闭，入口为「设置 → 外观与显示 → 隐私模式」。
* **macOS 原生体验** — 支持浅色 / 深色外观、中文 / English、静默开机自启、快捷键刷新，以及应用内查看更新日志、下载安装并自动重启。
* **本地诊断** — 日志自动轮转并默认脱敏；可在设置中导出诊断包，由用户自行检查和分享，应用不会自动上传。

---

### 📸 界面预览

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="用量概览"><br>
  <sub><b>用量概览</b>：按时间范围汇总 Tokens 与费用，查看用量趋势、缓存命中率、用量构成和高消耗对话</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="对话明细"><br>
  <sub><b>对话明细</b>：按项目筛选或搜索对话，查看单次对话的 Token 构成、估算费用、模型与速度档位</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-projects.png" width="720" alt="项目分析"><br>
  <sub><b>项目分析</b>：按项目查看用量与费用，分析每日趋势、工具与模型、分支和高消耗对话</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-quota.png" width="720" alt="额度监控"><br>
  <sub><b>额度监控</b>：查看 Codex 与 Claude Code 当前 5 小时和周周期用量、官方已用比例及额度变化记录</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/settings.png" width="720" alt="服务与账号设置"><br>
  <sub><b>服务与账号设置</b>：一页开关服务、选择菜单栏与悬浮窗，并在 Codex 下添加其他账号</sub>
</p>

---

## 📦 快速安装

> **运行环境**：macOS 14 (Sonoma) 或更新版本。<br>
> **前置条件**：相关 AI 编程工具需已在终端或桌面端完成至少一次登录。

1. 进入 [Releases 页面](https://github.com/nanvon/cc-bar/releases/latest) 下载最新的 `CCBar.dmg`（或 `CCBar.app.zip`）。
2. 打开 DMG，将 `CCBar.app` 拖入 `/Applications` 文件夹即可。

首次升级到含应用内更新器的版本，需要按上述步骤手动安装一次。此后可在「设置 → 通用 → 检查更新」查看更新内容，点击「下载并安装」后自动完成安装并重新启动。

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

用量日志在本机解析与保存；额度、Cursor 远端计量、服务状态及价格目录通过对应服务的网络接口查询。应用不上传本机会话日志或项目数据。

### 凭据读取与刷新策略

| 服务 / 目标 | 凭据存储位置 | 读写权限 | 行为机制与安全保障 |
| :--- | :--- | :---: | :--- |
| **Codex** | `~/.codex/auth.json`<br>导入的其他账号：CCBar 自己的 Keychain 条目 | 读 / 写 | 临期时使用 `refresh_token` 自动续期，新令牌写回原存储位置。续期前二次确认本地文件，避免与 `codex` CLI 冲突抢刷。 |
| **Claude Code** | `~/.claude/.credentials.json`<br>或 macOS Keychain | **严格只读** | **绝不刷新或篡改凭据**。因 Anthropic 刷新令牌为一次性，第三方刷新会导致 CLI 被踢下线。过期时保留快照并提示终端重登；必要时提供安全 CLI 兜底。 |
| **Antigravity** | `~/.gemini/jetski-standalone-oauth-token`<br>`~/.gemini/oauth_creds.json` (兜底) | 读 / 写 | 优先读取独立 OAuth Token，临期自动续期回写。Cloud Mode 直连 Google 云端 API，无需本地 IDE 运行。 |
| **Cursor** | `~/Library/Application Support/Cursor`<br>`/User/globalStorage/state.vscdb` | **严格只读** | 仅读 `cursorAuth/accessToken` 构造 Cookie 查询用量，绝不碰 refresh token/OAuth，不写回 Cursor SQLite 或 Keychain。 |
| **Command Code** | 5 级本地来源或 macOS Keychain | 读 / Keychain | 只读自动探测按 `~/.commandcode/auth.json` → `~/.pi/agent/auth.json` → `~/.local/share/opencode/auth.json` → 环境变量 → Keychain 依次尝试；也可在设置中切换为手动 API Key，由 macOS Keychain 保存。 |
| **本地会话日志** | `~/.codex/sessions`、`~/.claude/projects`<br>`~/.pi/agent/sessions`、OpenCode SQLite<br>`~/.dsh/sessions` | **严格只读** | 解析用量、模型及项目元数据，读取标题索引或从日志提取对话标题；标题缺失时可能使用用户消息摘要。不上传会话内容，不改写源日志。 |

### 系统权限与零遥测承诺
* **无受保护文件夹访问**：对桌面、文稿、下载、音乐、图片、影片等受保护目录，以及家目录以外的路径，项目归组仅做**纯文本路径分词**，绝不调用文件系统接口，因此**不会触发系统的隐私权限弹窗**。
* **零外部遥测**：应用不采集或上报用户行为遥测；Sparkle 更新器只用于检查和安装更新，不发送系统画像。
* **截图隐私与本地数据**：隐私模式只隐藏界面中的身份信息，真实标题、路径与统计仍保存在本机；分享截图前可检查画面，导出文件和剪贴板需自行确认。
* **诊断日志只在本机**：运行日志写在 `~/Library/Logs/CCBar/`（约 8 MB 上限，自动轮转），默认脱敏——不含登录令牌、明文邮箱、对话内容、文件内容或项目名，账号只以单向哈希出现。App 不会上传任何日志。

> [!TIP]
> 如果你对预编译二进制包有所顾虑，欢迎审阅完整源码并[从源码自主构建](#-从源码构建)。

> [!NOTE]
> **遇到问题怎么反馈**：打开「设置 → 通用 → 诊断 → 导出诊断日志」，确认提示后会生成一个 zip 并在 Finder 中选中，把它附在 [Issue](https://github.com/nanvon/cc-bar/issues) 里即可。包内的 `summary.txt` 是纯文本，发送前可以自己先打开看一眼。

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
SPARKLE_PUBLIC_ED_KEY="你的更新公钥" ./scripts/build.sh
```

构建前需按 [更新签名配置](docs/打包发布.md#首次配置更新签名密钥) 设置 `SPARKLE_PUBLIC_ED_KEY` 公钥。构建脚本使用 `CODE_SIGNING_ALLOWED=NO` 编译，再逐层进行 ad-hoc 签名，产出 `dist/CCBar.dmg` 与 `dist/CCBar.app.zip`。安装包不绑定本机开发证书；支持的 CPU 架构以实际构建产物为准，首次启动的系统提示见上方安装说明。

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
