<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="cc-bar Logo">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">
  <b>macOS 原生 AI 额度监控与用量分析工具</b><br>
  在菜单栏实时监控 Codex、Claude Code、Cursor、Antigravity 配额与重置时间，本地离线分析 Tokens、费用与对话。
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/nanvon/cc-bar?color=brightgreen"></a>
  <img alt="Downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/total?color=blue">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="Latest Downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/latest/total?label=latest%20downloads&color=blue"></a>
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest">下载安装</a> ·
  <a href="#-服务支持矩阵">服务支持</a> ·
  <a href="#-核心特性">核心特性</a> ·
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

## ⚡ 服务支持矩阵

cc-bar 展示两类数据：**订阅额度**直连各服务官方接口获取剩余比例与重置时间；**本机用量**由本地日志解析或服务端计量汇总，不上传任何代码、项目数据或会话内容。

| 服务 / 工具 | 订阅额度监控 | 额度耗尽提醒 | 本地用量 / 费用统计 | 多账号同屏 | 凭据来源 |
| :--- | :--- | :---: | :--- | :---: | :--- |
| **Codex** | 5 小时 / 周额度、重置倒计时 | 支持 | 本地会话（含 `.zst` 压缩日志） | 支持 | `~/.codex/auth.json`（自动续期） |
| **Claude Code** | 5 小时 / 周 / 模型专属额度 | 支持 | 本地会话日志 | — | Keychain / 本地只读凭据 |
| **Antigravity** | Gemini 5 小时与周、Claude 辅助 | 支持 | — | — | Google Cloud OAuth（自动续期） |
| **Cursor** | Total / Auto / API（含 Unlimited） | 支持 | 账号全设备远端计量（今日 / 本期） | — | 本地 state.vscdb（严格只读） |
| **Command Code** | 5 小时 / 周额度、GOAT 月度 Credits | 支持 | — | — | 本地 5 级只读探测 / Keychain Key |
| **OpenCode Go** | 5 小时 / 周 / 月额度 | 支持 | — | — | OpenCode / Pi 本地只读探测 / Keychain Key |
| **Pi / OpenCode / DSH** | — | — | 本地会话日志（Pi / OpenCode / DSH 多帧 zstd） | — | 严格只读本地日志与数据库 |

---

## ✨ 核心特性

### ⚡ 实时配额与状态监控
* **常驻菜单栏与桌面悬浮窗** — 支持主要窗口、周窗口或双窗口模式；桌面悬浮窗边缘吸附、位置记忆，不抢占键盘焦点。
* **低额度系统通知** — 当 5 小时、周或计费周期额度低于设定阈值时发送 macOS 系统通知，同一周期仅提醒一次，点击通知直达用量统计。
* **低开销后台调度** — 额度查询、日志扫描与服务状态合并调度；锁屏与息屏降频，睡眠暂停、唤醒补刷，接口 429 自动退避。
* **多账号无缝并存** — Codex 支持粘贴 `auth.json` 或 PAT 导入多个账号同屏查看剩余额度与额外重置次数，不影响 CLI 登录状态。

### 📊 本地离线用量与项目分析
* **多维度统计分析** — 概览、对话、项目与额度四个页面，支持日 / 周 / 月粒度与自定义时间范围：
  * **用量概览**：堆叠图展示总 Tokens、费用与同期变化，按服务、Provider、模型或项目分析构成，统计缓存命中率。
  * **对话明细**：检索历史会话，查看输入、输出、缓存读写明细、请求数、模型构成与 Standard / Fast 速度档位费用拆分。
  * **项目分析**：按项目汇总用量趋势、高消耗对话与分支分布；Git worktree 自动归入主仓库。
  * **额度对比与预估**：对比当前周期的本机用量、用满预估与官方已用比例；支持开启「包含其他 Agent 中的 Codex 订阅用量」，将 Pi、OpenCode、DSH 中消耗的 Codex 额度合并计入。
* **规则变更自动重算** — 价格表或统计规则变化后自动重新计费；会话日志已清理的对话自动保留历史用量，不影响统计连续性。

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="用量概览">
</p>

<details>
  <summary><b>展开查看对话明细、项目分析与额度监控截图</b></summary>
  <br>
  <p align="center">
    <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="对话明细"><br><br>
    <img src="docs/Screenshots/statistics-projects.png" width="720" alt="项目分析"><br><br>
    <img src="docs/Screenshots/statistics-quota.png" width="720" alt="额度监控">
  </p>
</details>

### 💻 原生体验与隐私控制
* **一页管理与拖拽排序** — 「设置 → 服务与账号」一页开关所有服务，可整行拖拽自定义服务在菜单栏、Popover、悬浮窗与统计页的全局展示顺序。
* **截图隐私模式** — 一键匿名遮挡账号邮箱、项目路径、Git 分支与会话 ID，保留真实金额与图表，截图分享无负担。
* **应用内平滑升级** — 集成 Sparkle 更新器，直接在应用内查看更新说明、一键下载安装并自动重启。
* **本地诊断与零追踪** — 日志自动轮转且关键字段全脱敏；可手动导出诊断包，应用不含任何用户行为遥测。

<p align="center">
  <img src="docs/Screenshots/settings.png" width="720" alt="服务与账号设置">
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
| **Antigravity** | 系统钥匙串 `gemini / antigravity`（优先）<br>旧 jetski / CLI token / oauth_creds 文件（兼容） | 原始 GUI 登录只读；CCBar 续期缓存读 / 写；旧 jetski / oauth_creds 读 / 写 | 仅安装并登录桌面端即可识别账号、查询额度和自动续期，无需 agy。续期缓存按原始登录绑定，存 CCBar 自己的钥匙串。 |
| **Cursor** | `~/Library/Application Support/Cursor`<br>`/User/globalStorage/state.vscdb` | **严格只读** | 仅读 `cursorAuth/accessToken` 构造 Cookie 查询用量，绝不碰 refresh token/OAuth，不写回 Cursor SQLite 或 Keychain。 |
| **Command Code** | 5 级本地来源或 macOS Keychain | 读 / Keychain | 只读自动探测按 `~/.commandcode/auth.json` → `~/.pi/agent/auth.json` → `~/.local/share/opencode/auth.json` → 环境变量 → Keychain 依次尝试；也可在设置中切换为手动 API Key，由 macOS Keychain 保存。 |
| **OpenCode Go** | OpenCode / Pi 的 `auth.json` 或 macOS Keychain | 读 / Keychain | 只读自动探测按 OpenCode `auth.json` → `~/.pi/agent/auth.json` → 环境变量 `OPENCODE_API_KEY` → Keychain 依次尝试，读取其中的 `opencode-go` API Key；也可在设置中切换为手动 API Key，由 macOS Keychain 保存。 |
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

感谢 [LINUX DO](https://linux.do/) 社区的交流与反馈。

---

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
